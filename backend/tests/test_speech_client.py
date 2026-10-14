"""AzureSpeechClient.transcribe() with a fake SDK adapter: no native SDK, no Azure.

The fake session drives the sink from its own thread, like the SDK's native
callbacks.
"""

import io
import os
import subprocess
import sys
import threading
import time
import wave
from collections.abc import Callable
from contextlib import nullcontext
from typing import Any

import pytest

from app.config.settings import BACKEND_DIR, Settings
from app.integrations.speech import client as client_module
from app.integrations.speech.client import AzureSpeechClient, _Collector
from app.integrations.speech.errors import (
    SpeechBadResponseError,
    SpeechError,
    SpeechInvalidAudioError,
    SpeechNoSpeechError,
    SpeechNotConfiguredError,
    SpeechRateLimitedError,
    SpeechTimeoutError,
    SpeechUnavailableError,
)

ENDPOINT = "https://secret-speech-host.cognitiveservices.azure.com"
LANGUAGE = "ca-ES"
SESSION_ID = "0123456789abcdef0123456789abcdef"
SECRET_TRANSCRIPT = "my private dictated note"

ALL_CANCELLATION_CODES = [
    "NoError",
    "AuthenticationFailure",
    "BadRequest",
    "TooManyRequests",
    "Forbidden",
    "ConnectionFailure",
    "ServiceTimeout",
    "ServiceError",
    "ServiceUnavailable",
    "RuntimeError",
    "ServiceRedirectTemporary",
    "ServiceRedirectPermanent",
    "EmbeddedModelError",
]


def make_wav(frames: int = 16_000, fill: bytes = b"\x01\x02") -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16_000)
        wav.writeframes(fill * frames)
    return buffer.getvalue()


class Info:
    """Stand-in for _sdk.CancellationInfo (the client only reads its attributes)."""

    def __init__(self, end_of_stream: bool, code: str | None, session_id: str | None) -> None:
        self.end_of_stream = end_of_stream
        self.code = code
        self.session_id = session_id


def phrase(text: str) -> tuple[str, Any]:
    return ("phrase", text)


NO_MATCH = ("no_match", None)
STOPPED = ("stopped", None)
END_OF_STREAM = ("cancel", Info(True, "NoError", SESSION_ID))


def cancel(code: str | None, session_id: str | None = SESSION_ID) -> tuple[str, Any]:
    return ("cancel", Info(False, code, session_id))


def sleep(seconds: float) -> tuple[str, Any]:
    return ("sleep", seconds)


class FakeSession:
    def __init__(self, sink: Any, script: list[tuple[str, Any]], **behaviour: Any) -> None:
        self.sink = sink
        self.script = script
        self.behaviour = behaviour
        self.calls: list[str] = []
        self.release = threading.Event()  # unblocks hanging start/stop at test end

    def _play(self) -> None:
        for kind, value in self.script:
            if kind == "phrase":
                self.sink.on_phrase(value)
            elif kind == "no_match":
                self.sink.on_no_match()
            elif kind == "cancel":
                self.sink.on_canceled(value)
            elif kind == "stopped":
                self.sink.on_stopped()
            elif kind == "sleep":
                time.sleep(value)

    def start(self) -> None:
        self.calls.append("start")
        if error := self.behaviour.get("start_error"):
            raise error
        if self.behaviour.get("hang_start"):
            self.release.wait(10)
            return
        threading.Thread(target=self._play, daemon=True).start()

    def stop(self) -> None:
        self.calls.append("stop")
        if error := self.behaviour.get("stop_error"):
            raise error
        if self.behaviour.get("hang_stop"):
            self.release.wait(10)

    def close(self) -> None:
        self.calls.append("close")
        if error := self.behaviour.get("close_error"):
            raise error


class FakeSdk:
    """Stands in for _sdk.open_recognition; records every call."""

    def __init__(
        self,
        script: list[tuple[str, Any]] | Callable[[bytes], list[tuple[str, Any]]] | None = None,
        **behaviour: Any,
    ) -> None:
        self.script = script if script is not None else [phrase("hola"), END_OF_STREAM, STOPPED]
        self.behaviour = behaviour
        self.opened: list[dict[str, Any]] = []
        self.sessions: list[FakeSession] = []
        self.lock = threading.Lock()

    def __call__(self, **kwargs: Any) -> FakeSession:
        if error := self.behaviour.get("open_error"):
            raise error
        script = self.script(kwargs["pcm"]) if callable(self.script) else self.script
        session = FakeSession(kwargs["sink"], script, **self.behaviour)
        with self.lock:
            self.opened.append(kwargs)
            self.sessions.append(session)
        return session


class FakeCredentialFactory:
    def __init__(self, error: Exception | None = None) -> None:
        self.error = error
        self.calls = 0
        self.credential = object()

    def __call__(self) -> object:
        self.calls += 1
        if self.error is not None:
            raise self.error
        return self.credential


def make_client(
    sdk: FakeSdk | None = None,
    *,
    credentials: FakeCredentialFactory | None = None,
    timeout: float = 5,
) -> tuple[AzureSpeechClient, FakeSdk, FakeCredentialFactory]:
    sdk = sdk or FakeSdk()
    credentials = credentials or FakeCredentialFactory()
    client = AzureSpeechClient(
        endpoint=ENDPOINT + "/",
        recognition_language=LANGUAGE,
        stt_timeout_seconds=timeout,
        credential_factory=credentials,
        open_recognition=sdk,
    )
    return client, sdk, credentials


def transcribe(sdk: FakeSdk, **kwargs: Any) -> str:
    client, _, _ = make_client(sdk, **kwargs)
    return client.transcribe(make_wav())


def failure(sdk: FakeSdk, **kwargs: Any) -> SpeechError:
    with pytest.raises(SpeechError) as exc_info:
        transcribe(sdk, **kwargs)
    return exc_info.value


@pytest.fixture(autouse=True)
def short_stop_grace(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(client_module, "STOP_GRACE_SECONDS", 0.3)


# --- transcripts ----------------------------------------------------------------------


def test_one_phrase_is_returned() -> None:
    assert transcribe(FakeSdk([phrase("Bon dia, Jarvis."), END_OF_STREAM, STOPPED])) == (
        "Bon dia, Jarvis."
    )


def test_phrases_are_joined_in_order_with_single_spaces() -> None:
    sdk = FakeSdk([phrase("Primer."), NO_MATCH, phrase("Segon."), phrase("Tercer."), STOPPED])

    assert transcribe(sdk) == "Primer. Segon. Tercer."


def test_whitespace_is_trimmed_and_blank_phrases_skipped() -> None:
    sdk = FakeSdk([phrase("  Hola  "), phrase("   "), phrase(""), phrase("\nmón\t"), STOPPED])

    assert transcribe(sdk) == "Hola món"


def test_session_stopped_alone_completes_the_call() -> None:
    assert transcribe(FakeSdk([phrase("ok"), STOPPED])) == "ok"


@pytest.mark.parametrize(
    "script",
    [
        [NO_MATCH, END_OF_STREAM, STOPPED],
        [NO_MATCH, NO_MATCH, STOPPED],
        [END_OF_STREAM, STOPPED],
        [STOPPED],
        [phrase("   "), phrase(""), STOPPED],
    ],
)
def test_no_speech(script: list[tuple[str, Any]]) -> None:
    error = failure(FakeSdk(script))

    assert type(error) is SpeechNoSpeechError
    assert error.reason == "no_speech"


def test_no_speech_carries_the_session_id() -> None:
    assert failure(FakeSdk([END_OF_STREAM, STOPPED])).session_id == SESSION_ID


# --- request ----------------------------------------------------------------------------


def test_the_adapter_receives_pcm_language_endpoint_and_credential() -> None:
    client, sdk, credentials = make_client()

    client.transcribe(make_wav(16_000, fill=b"\xab\xcd"))

    [opened] = sdk.opened
    assert opened["pcm"] == b"\xab\xcd" * 16_000  # PCM only, no RIFF header
    assert opened["language"] == LANGUAGE
    assert opened["endpoint"] == ENDPOINT
    assert opened["credential"] is credentials.credential


def test_invalid_audio_never_touches_the_credential_or_sdk() -> None:
    client, sdk, credentials = make_client()

    with pytest.raises(SpeechInvalidAudioError):
        client.transcribe(b"not a wav")

    assert credentials.calls == 0
    assert sdk.opened == []


# --- cancellations ------------------------------------------------------------------------


EXPECTED = {
    "AuthenticationFailure": (SpeechUnavailableError, "unauthorized"),
    "Forbidden": (SpeechUnavailableError, "forbidden"),
    "BadRequest": (SpeechUnavailableError, "bad_request"),
    "TooManyRequests": (SpeechRateLimitedError, "too_many_requests"),
    "ConnectionFailure": (SpeechUnavailableError, "connection"),
    "ServiceTimeout": (SpeechTimeoutError, "service_timeout"),
    "ServiceError": (SpeechUnavailableError, "server_error"),
    "ServiceUnavailable": (SpeechUnavailableError, "service_unavailable"),
    "ServiceRedirectTemporary": (SpeechUnavailableError, "redirect"),
    "ServiceRedirectPermanent": (SpeechUnavailableError, "redirect"),
    "RuntimeError": (SpeechUnavailableError, "sdk_error"),
    "EmbeddedModelError": (SpeechUnavailableError, "sdk_error"),
    "NoError": (SpeechBadResponseError, "unexpected_result"),
    "SomethingNew": (SpeechBadResponseError, "unexpected_result"),
    None: (SpeechBadResponseError, "unexpected_result"),
}


def test_every_sdk_cancellation_code_is_mapped() -> None:
    assert set(ALL_CANCELLATION_CODES) <= set(EXPECTED)


@pytest.mark.parametrize(("code", "expected"), EXPECTED.items())
def test_error_cancellations_are_mapped(code: str | None, expected: tuple[type, str]) -> None:
    error = failure(FakeSdk([cancel(code), STOPPED]))

    assert type(error) is expected[0]
    assert error.reason == expected[1]
    assert error.code == code if code is not None else error.code is None
    assert error.session_id == SESSION_ID
    assert error.__cause__ is None


def test_an_error_cancellation_wins_over_partial_phrases() -> None:
    error = failure(FakeSdk([phrase(SECRET_TRANSCRIPT), cancel("ConnectionFailure"), STOPPED]))

    assert isinstance(error, SpeechUnavailableError)
    assert error.reason == "connection"


def test_an_error_cancellation_completes_without_session_stopped() -> None:
    started = time.monotonic()

    error = failure(FakeSdk([cancel("Forbidden")]), timeout=5)

    assert error.reason == "forbidden"
    assert time.monotonic() - started < 1


def test_a_malformed_session_id_is_dropped() -> None:
    error = failure(FakeSdk([cancel("Forbidden", session_id="id with spaces\n"), STOPPED]))

    assert error.session_id is None


# --- timeout --------------------------------------------------------------------------------


def test_recognition_that_never_ends_times_out_at_the_deadline() -> None:
    sdk = FakeSdk([phrase("still talking"), sleep(5)])
    started = time.monotonic()

    error = failure(sdk, timeout=0.3)

    elapsed = time.monotonic() - started
    assert type(error) is SpeechTimeoutError
    assert error.reason == "timeout"
    assert 0.3 <= elapsed < 0.3 + 0.3 + 0.4  # deadline + stop grace + margin
    assert sdk.sessions[0].calls == ["start", "stop", "close"]


def test_a_hanging_start_times_out() -> None:
    sdk = FakeSdk(hang_start=True)
    started = time.monotonic()

    error = failure(sdk, timeout=0.3)

    assert error.reason == "timeout"
    assert time.monotonic() - started < 1.2
    assert sdk.sessions[0].calls[-1] == "close"
    sdk.sessions[0].release.set()


def test_a_hanging_stop_does_not_extend_the_call_beyond_the_grace() -> None:
    sdk = FakeSdk([phrase("ok"), STOPPED], hang_stop=True)
    started = time.monotonic()

    assert transcribe(sdk) == "ok"

    assert time.monotonic() - started < 0.3 + 0.5
    assert sdk.sessions[0].calls == ["start", "stop", "close"]
    sdk.sessions[0].release.set()


# --- cleanup never replaces the outcome -------------------------------------------------------


def test_success_with_a_failing_stop_still_returns_the_transcript() -> None:
    sdk = FakeSdk([phrase("Hola"), STOPPED], stop_error=RuntimeError("stop failed"))

    assert transcribe(sdk) == "Hola"
    assert sdk.sessions[0].calls == ["start", "stop", "close"]


def test_timeout_with_a_failing_stop_remains_a_timeout() -> None:
    sdk = FakeSdk([sleep(5)], stop_error=RuntimeError("stop failed"))

    error = failure(sdk, timeout=0.2)

    assert type(error) is SpeechTimeoutError
    assert error.reason == "timeout"


def test_cancellation_with_a_failing_stop_remains_the_cancellation_error() -> None:
    sdk = FakeSdk([cancel("TooManyRequests"), STOPPED], stop_error=RuntimeError("stop failed"))

    error = failure(sdk)

    assert type(error) is SpeechRateLimitedError
    assert error.reason == "too_many_requests"


def test_a_failing_start_is_an_sdk_error() -> None:
    sdk = FakeSdk(start_error=RuntimeError("secret sdk text"))

    error = failure(sdk)

    assert type(error) is SpeechUnavailableError
    assert error.reason == "sdk_error"
    assert error.__cause__ is None
    assert error.__suppress_context__ is True
    assert sdk.sessions[0].calls == ["start", "stop", "close"]


@pytest.mark.parametrize(
    "script", [[phrase("ok"), STOPPED], [cancel("Forbidden")], [sleep(5)], [STOPPED]]
)
def test_close_errors_never_propagate(script: list[tuple[str, Any]]) -> None:
    sdk = FakeSdk(script, close_error=RuntimeError("close failed"))
    client, _, _ = make_client(sdk, timeout=0.2)

    try:
        client.transcribe(make_wav())
    except SpeechError as error:
        assert "close failed" not in str(error)
    assert sdk.sessions[0].calls[-1] == "close"


def test_a_failing_open_is_an_sdk_error() -> None:
    error = failure(FakeSdk(open_error=OSError("libasound.so.2: secret path")))

    assert type(error) is SpeechUnavailableError
    assert error.reason == "sdk_error"
    assert error.__cause__ is None


@pytest.mark.parametrize(
    ("script", "succeeds"),
    [
        ([phrase("ok"), STOPPED], True),
        ([cancel("ServiceError"), STOPPED], False),
        ([STOPPED], False),
        ([sleep(5)], False),
    ],
)
def test_the_session_is_always_stopped_and_closed(
    script: list[tuple[str, Any]], succeeds: bool
) -> None:
    sdk = FakeSdk(script)

    with nullcontext() if succeeds else pytest.raises(SpeechError):
        transcribe(sdk, timeout=0.2)

    assert sdk.sessions[0].calls == ["start", "stop", "close"]


# --- late callbacks -------------------------------------------------------------------------


def test_late_callbacks_after_close_change_nothing() -> None:
    collector = _Collector()
    collector.on_phrase("first")
    phrases, cancellation = collector.close()

    collector.on_phrase("late")
    collector.on_canceled(Info(False, "Forbidden", SESSION_ID))
    collector.on_stopped()
    collector.on_no_match()

    assert phrases == ("first",)
    assert cancellation is None
    assert collector.close() == (("first",), None)


def test_late_callbacks_after_a_timeout_do_not_raise_or_leak() -> None:
    sdk = FakeSdk([sleep(0.4), phrase("late phrase"), cancel("Forbidden"), STOPPED])

    error = failure(sdk, timeout=0.2)
    time.sleep(0.5)  # let the late callbacks fire into the closed collector

    assert error.reason == "timeout"


def test_only_the_first_cancellation_is_kept() -> None:
    error = failure(FakeSdk([cancel("TooManyRequests"), cancel("Forbidden"), STOPPED]))

    assert error.reason == "too_many_requests"


# --- configuration and credential ------------------------------------------------------------


def test_from_settings_requires_an_endpoint() -> None:
    with pytest.raises(SpeechNotConfiguredError):
        AzureSpeechClient.from_settings(Settings(_env_file=None))


def test_from_settings_uses_the_speech_settings() -> None:
    settings = Settings(
        _env_file=None,
        speech_endpoint="https://jarvis-speech-test.cognitiveservices.azure.com",
        speech_recognition_language="es-ES",
        speech_stt_timeout_seconds=12,
    )

    client = AzureSpeechClient.from_settings(settings)

    assert client._endpoint == "https://jarvis-speech-test.cognitiveservices.azure.com"
    assert client._recognition_language == "es-ES"
    assert client._stt_timeout_seconds == 12
    assert client._credential is None


def test_the_credential_is_created_on_first_use_and_reused() -> None:
    client, _, credentials = make_client()
    assert credentials.calls == 0
    assert "credential_created=False" in repr(client)

    client.transcribe(make_wav())
    client.transcribe(make_wav())

    assert credentials.calls == 1
    assert "credential_created=True" in repr(client)


def test_a_failing_credential_is_a_credential_error() -> None:
    credentials = FakeCredentialFactory(error=ValueError("secret azure identity text"))
    client, sdk, _ = make_client(credentials=credentials)

    with pytest.raises(SpeechUnavailableError) as exc_info:
        client.transcribe(make_wav())

    assert exc_info.value.reason == "credential"
    assert exc_info.value.__cause__ is None
    assert "secret" not in str(exc_info.value)
    assert sdk.opened == []


def test_a_native_sdk_that_cannot_load_is_an_sdk_error(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setitem(sys.modules, "app.integrations.speech._sdk", None)  # import fails
    client = AzureSpeechClient(
        endpoint=ENDPOINT,
        recognition_language=LANGUAGE,
        stt_timeout_seconds=5,
        credential_factory=FakeCredentialFactory(),
    )

    with pytest.raises(SpeechUnavailableError) as exc_info:
        client.transcribe(make_wav())

    assert exc_info.value.reason == "sdk_error"


def test_constructing_and_importing_load_nothing() -> None:
    script = (
        "import sys\n"
        "import azure.identity\n"
        "created = []\n"
        "azure.identity.DefaultAzureCredential = lambda *a, **k: created.append(1)\n"
        "from app.config.settings import Settings\n"
        "from app.integrations.speech import AzureSpeechClient\n"
        "client = AzureSpeechClient.from_settings(Settings(_env_file=None,"
        " speech_endpoint='https://jarvis-speech-test.cognitiveservices.azure.com'))\n"
        "assert created == [], created\n"
        "assert not [m for m in sys.modules if m.startswith('azure.cognitiveservices')]\n"
        "assert 'app.integrations.speech._sdk' not in sys.modules\n"
    )
    env = {k: v for k, v in os.environ.items() if not k.startswith("JARVIS_")}

    subprocess.run([sys.executable, "-c", script], cwd=BACKEND_DIR, env=env, check=True)


# --- concurrency -------------------------------------------------------------------------------


def test_concurrent_calls_do_not_share_state() -> None:
    def script(pcm: bytes) -> list[tuple[str, Any]]:
        marker = f"frames-{len(pcm) // 2}"
        return [sleep(0.05), phrase(marker), sleep(0.05), phrase("end"), STOPPED]

    client, sdk, credentials = make_client(FakeSdk(script))
    frame_counts = [8_000 + 100 * i for i in range(8)]
    results: dict[int, str] = {}
    errors: list[BaseException] = []
    barrier = threading.Barrier(len(frame_counts))

    def run(frames: int) -> None:
        try:
            barrier.wait()
            results[frames] = client.transcribe(make_wav(frames))
        except BaseException as error:
            errors.append(error)

    threads = [threading.Thread(target=run, args=(n,)) for n in frame_counts]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(10)

    assert errors == []
    assert results == {n: f"frames-{n} end" for n in frame_counts}
    assert credentials.calls == 1
    assert len(sdk.sessions) == len(frame_counts)
    assert len({id(session.sink) for session in sdk.sessions}) == len(frame_counts)


# --- nothing sensitive ------------------------------------------------------------------------


def test_errors_and_client_never_contain_sensitive_values() -> None:
    client, _, _ = make_client()
    assert "secret-speech-host" not in repr(client)

    scripts = [
        [phrase(SECRET_TRANSCRIPT), cancel("Forbidden"), STOPPED],
        [phrase(SECRET_TRANSCRIPT), sleep(5)],
        [END_OF_STREAM, STOPPED],
    ]
    for script in scripts:
        error = failure(FakeSdk(script), timeout=0.2)
        for text in (str(error), repr(error), repr(vars(error))):
            assert "secret-speech-host" not in text
            assert SECRET_TRANSCRIPT not in text
            assert "\x01\x02" not in text
