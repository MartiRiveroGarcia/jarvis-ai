"""Azure AI Speech client: speech-to-text and text-to-speech.

Each call is independent: its own recognizer or synthesizer and result state. Only
the Microsoft Entra ID credential is shared, created on first use. There are no
API keys, regions or manual tokens: the SDK requests and refreshes its own tokens
from the credential for the resource's custom-domain endpoint.
"""

import threading
import time
from collections.abc import Callable
from contextlib import suppress
from types import ModuleType
from typing import TYPE_CHECKING, Protocol

from app.integrations.speech.audio import parse_wav
from app.integrations.speech.errors import (
    SpeechBadResponseError,
    SpeechError,
    SpeechInvalidTextError,
    SpeechNoSpeechError,
    SpeechNotConfiguredError,
    SpeechRateLimitedError,
    SpeechTimeoutError,
    SpeechUnavailableError,
)

if TYPE_CHECKING:
    from azure.core.credentials import TokenCredential

    from app.config.settings import Settings
    from app.integrations.speech._sdk import (
        CancellationInfo,
        RecognitionSession,
        RecognitionSink,
        SynthesisOutcome,
        SynthesisSession,
    )

# How long cleanup may wait for recognition or synthesis to stop. Cleanup never
# changes the result.
STOP_GRACE_SECONDS = 2.0

# Text-to-speech input limit, in Unicode code points after trimming.
MAX_SYNTHESIS_TEXT_LENGTH = 5000


CredentialFactory = Callable[[], "TokenCredential"]


class OpenRecognition(Protocol):
    def __call__(
        self,
        *,
        endpoint: str,
        credential: "TokenCredential",
        language: str,
        pcm: bytes,
        sink: "RecognitionSink",
    ) -> "RecognitionSession": ...


class OpenSynthesis(Protocol):
    def __call__(
        self,
        *,
        endpoint: str,
        credential: "TokenCredential",
        voice: str,
        text: str,
    ) -> "SynthesisSession": ...


class AzureSpeechClient:
    """Speech-to-text and text-to-speech against one Azure Speech resource.

    Constructing the client stores configuration only. The credential and the
    native SDK are loaded on the first transcribe() or synthesize() call.
    """

    def __init__(
        self,
        *,
        endpoint: str,
        recognition_language: str,
        stt_timeout_seconds: float,
        voice: str,
        tts_timeout_seconds: float,
        credential_factory: CredentialFactory | None = None,
        open_recognition: OpenRecognition | None = None,
        open_synthesis: OpenSynthesis | None = None,
    ) -> None:
        self._endpoint = endpoint.rstrip("/")
        self._recognition_language = recognition_language
        self._stt_timeout_seconds = stt_timeout_seconds
        self._voice = voice
        self._tts_timeout_seconds = tts_timeout_seconds
        self._credential_factory = credential_factory or _default_credential
        self._open_recognition = open_recognition
        self._open_synthesis = open_synthesis
        self._credential: TokenCredential | None = None
        self._lock = threading.Lock()

    @classmethod
    def from_settings(cls, settings: "Settings") -> "AzureSpeechClient":
        if settings.speech_endpoint is None:
            raise SpeechNotConfiguredError
        return cls(
            endpoint=settings.speech_endpoint,
            recognition_language=settings.speech_recognition_language,
            stt_timeout_seconds=settings.speech_stt_timeout_seconds,
            voice=settings.speech_voice,
            tts_timeout_seconds=settings.speech_tts_timeout_seconds,
        )

    def __repr__(self) -> str:
        # Never expose the endpoint.
        return f"{type(self).__name__}(credential_created={self._credential is not None})"

    def transcribe(self, wav: bytes) -> str:
        """Return the transcript of a 16 kHz, 16-bit, mono PCM WAV recording.

        Raises a SpeechError subclass on failure.
        """
        audio = parse_wav(wav)  # before anything touches Azure
        deadline = time.monotonic() + self._stt_timeout_seconds
        credential = self._get_credential()
        open_recognition = self._recognition_opener()

        collector = _Collector()
        try:
            session = open_recognition(
                endpoint=self._endpoint,
                credential=credential,
                language=self._recognition_language,
                pcm=audio.pcm,
                sink=collector,
            )
        except Exception:
            raise SpeechUnavailableError(reason="sdk_error") from None

        try:
            _recognize(session, collector, deadline)
        finally:
            # The outcome is fixed before cleanup; cleanup can never replace it.
            phrases, cancellation = collector.close()
            _best_effort(session.stop, STOP_GRACE_SECONDS)
            _close_quietly(session)

        return _transcript(phrases, cancellation)

    def synthesize(self, text: str) -> bytes:
        """Return MP3 audio (24 kHz, 48 kbit/s, mono) of [text] in the configured voice.

        Plain text only (no SSML). Raises a SpeechError subclass on failure.
        """
        clean_text = _validate_text(text)  # before anything touches Azure
        deadline = time.monotonic() + self._tts_timeout_seconds
        credential = self._get_credential()
        open_synthesis = self._synthesis_opener()

        try:
            session = open_synthesis(
                endpoint=self._endpoint,
                credential=credential,
                voice=self._voice,
                text=clean_text,
            )
        except Exception:
            raise SpeechUnavailableError(reason="sdk_error") from None

        try:
            outcome = _synthesize(session, deadline)
        finally:
            _close_quietly(session)
        return _audio(outcome)

    def _get_credential(self) -> "TokenCredential":
        if self._credential is None:
            with self._lock:
                if self._credential is None:
                    try:
                        self._credential = self._credential_factory()
                    except Exception:
                        raise SpeechUnavailableError(reason="credential") from None
        return self._credential

    def _recognition_opener(self) -> OpenRecognition:
        if self._open_recognition is not None:
            return self._open_recognition
        return _adapter().open_recognition

    def _synthesis_opener(self) -> OpenSynthesis:
        if self._open_synthesis is not None:
            return self._open_synthesis
        return _adapter().open_synthesis


def _adapter() -> ModuleType:
    try:
        from app.integrations.speech import _sdk  # loads the native SDK
    except Exception:
        raise SpeechUnavailableError(reason="sdk_error") from None
    return _sdk


def _default_credential() -> "TokenCredential":
    from azure.identity import DefaultAzureCredential

    return DefaultAzureCredential()


class _Collector:
    """Per-call recognition state, written by SDK callbacks on native threads.

    Once closed, callbacks are ignored: nothing can change a result already returned.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._done = threading.Event()
        self._closed = False
        self._phrases: list[str] = []
        self._cancellation: CancellationInfo | None = None

    def on_phrase(self, text: str) -> None:
        phrase = text.strip()
        with self._lock:
            if not self._closed and phrase:
                self._phrases.append(phrase)

    def on_no_match(self) -> None:
        """Nothing to record: no-match results only mean no phrase."""

    def on_canceled(self, info: "CancellationInfo") -> None:
        with self._lock:
            if self._closed or self._cancellation is not None:
                return
            self._cancellation = info
        if not info.end_of_stream:
            self._done.set()

    def on_stopped(self) -> None:
        self._done.set()

    def wait(self, timeout: float) -> bool:
        return self._done.wait(timeout)

    def close(self) -> tuple[tuple[str, ...], "CancellationInfo | None"]:
        with self._lock:
            self._closed = True
            return tuple(self._phrases), self._cancellation


def _recognize(session: "RecognitionSession", collector: _Collector, deadline: float) -> None:
    """Run recognition until it ends or the deadline passes."""
    try:
        started = _run_bounded(session.start, _remaining(deadline))
    except Exception:
        raise SpeechUnavailableError(reason="sdk_error") from None
    if not started or not collector.wait(_remaining(deadline)):
        raise SpeechTimeoutError(reason="timeout")


def _validate_text(text: object) -> str:
    if not isinstance(text, str):
        raise SpeechInvalidTextError(reason="invalid_type")
    clean_text = text.strip()
    if not clean_text:
        raise SpeechInvalidTextError(reason="empty")
    if len(clean_text) > MAX_SYNTHESIS_TEXT_LENGTH:  # code points, like the backend's other limits
        raise SpeechInvalidTextError(reason="too_long")
    return clean_text


def _synthesize(session: "SynthesisSession", deadline: float) -> "SynthesisOutcome":
    """Run synthesis until it returns a result or the deadline passes.

    A returned result means the synthesis is over, so it is not stopped. Only when
    the call failed or is still running is a bounded, best-effort stop requested;
    it can never replace the timeout or SDK error.
    """
    try:
        finished, outcome = _call_bounded(session.synthesize, _remaining(deadline))
    except Exception:
        _best_effort(session.stop, STOP_GRACE_SECONDS)  # its state is uncertain
        raise SpeechUnavailableError(reason="sdk_error") from None
    if not finished or outcome is None:
        _best_effort(session.stop, STOP_GRACE_SECONDS)
        raise SpeechTimeoutError(reason="timeout")
    return outcome


def _audio(outcome: "SynthesisOutcome") -> bytes:
    if outcome.kind == "completed":
        if not outcome.audio:
            raise SpeechBadResponseError(reason="empty_audio")
        return outcome.audio
    if outcome.kind == "canceled" and outcome.cancellation is not None:
        raise _cancellation_error(outcome.cancellation)
    raise SpeechBadResponseError(reason="unexpected_result")


def _transcript(phrases: tuple[str, ...], cancellation: "CancellationInfo | None") -> str:
    session_id = cancellation.session_id if cancellation is not None else None
    if cancellation is not None and not cancellation.end_of_stream:
        # An error wins over any partial transcript.
        raise _cancellation_error(cancellation)
    transcript = " ".join(phrases).strip()
    if not transcript:
        raise SpeechNoSpeechError(session_id=session_id)
    return transcript


_UNAVAILABLE_REASONS = {
    "AuthenticationFailure": "unauthorized",
    "Forbidden": "forbidden",
    "BadRequest": "bad_request",  # the audio is already validated: our configuration
    "ConnectionFailure": "connection",
    "ServiceError": "server_error",
    "ServiceUnavailable": "service_unavailable",
    "ServiceRedirectTemporary": "redirect",
    "ServiceRedirectPermanent": "redirect",
    "RuntimeError": "sdk_error",
    "EmbeddedModelError": "sdk_error",
}


def _cancellation_error(info: "CancellationInfo") -> SpeechError:
    code, session_id = info.code, info.session_id
    if code == "TooManyRequests":
        return SpeechRateLimitedError(reason="too_many_requests", code=code, session_id=session_id)
    if code == "ServiceTimeout":
        return SpeechTimeoutError(reason="service_timeout", code=code, session_id=session_id)
    if code in _UNAVAILABLE_REASONS:
        return SpeechUnavailableError(
            reason=_UNAVAILABLE_REASONS[code], code=code, session_id=session_id
        )
    return SpeechBadResponseError(reason="unexpected_result", code=code, session_id=session_id)


def _remaining(deadline: float) -> float:
    return max(0.0, deadline - time.monotonic())


def _call_bounded[T](fn: Callable[[], T], timeout: float) -> tuple[bool, T | None]:
    """Run a blocking SDK call for at most [timeout] seconds.

    The SDK's futures have no timeout, so the call runs in a daemon thread. Returns
    (False, None) if it has not finished, (True, value) if it has; re-raises its
    exception if it failed.
    """
    outcome: dict[str, object] = {}

    def target() -> None:
        try:
            outcome["value"] = fn()
        except BaseException as error:  # re-raised in the caller
            outcome["error"] = error

    thread = threading.Thread(target=target, name="jarvis-speech-sdk", daemon=True)
    thread.start()
    thread.join(timeout)
    if thread.is_alive():
        return False, None
    if "error" in outcome:
        raise outcome["error"]  # type: ignore[misc]
    return True, outcome.get("value")  # type: ignore[return-value]


def _run_bounded(fn: Callable[[], None], timeout: float) -> bool:
    finished, _ = _call_bounded(fn, timeout)
    return finished


def _best_effort(fn: Callable[[], None], timeout: float) -> None:
    with suppress(Exception):  # cleanup must not replace the outcome
        _run_bounded(fn, timeout)


def _close_quietly(session: "RecognitionSession") -> None:
    with suppress(Exception):
        session.close()
