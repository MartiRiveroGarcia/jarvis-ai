"""AzureSpeechClient.transcribe() with a fake SDK adapter: no native SDK, no Azure.

The fake session drives the sink from its own thread, like the SDK's native
callbacks.
"""

import io
import logging
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
from azure.core.credentials import AccessToken

from app.config.settings import BACKEND_DIR, Settings
from app.integrations import speech as speech_package
from app.integrations.speech import client as client_module
from app.integrations.speech.client import ENTRA_SCOPE, AzureSpeechClient, _Collector
from app.integrations.speech.errors import (
    SpeechBadResponseError,
    SpeechError,
    SpeechInvalidAudioError,
    SpeechInvalidTextError,
    SpeechNoSpeechError,
    SpeechNotConfiguredError,
    SpeechRateLimitedError,
    SpeechTimeoutError,
    SpeechUnavailableError,
)

REGION = "swedencentral"
RESOURCE_ID = (
    "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg"
    "/providers/Microsoft.CognitiveServices/accounts/secret-speech-account"
)
LANGUAGES = ("ca-ES", "es-ES", "en-US", "zh-CN")
VOICE = "ca-ES-AlbaNeural"
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


class FakeCredential:
    """Hands out a new token on every request, like a credential near expiry."""

    def __init__(self, error: Exception | None = None) -> None:
        self.error = error
        self.requests: list[tuple[str, ...]] = []
        self.lock = threading.Lock()

    def get_token(self, *scopes: str, **kwargs: Any) -> AccessToken:
        with self.lock:
            self.requests.append(scopes)
            count = len(self.requests)
        if self.error is not None:
            raise self.error
        return AccessToken(f"secret-token-{count}", int(time.time()) + 3600)


def authorization(token_number: int) -> str:
    return f"aad#{RESOURCE_ID}#secret-token-{token_number}"


class FakeCredentialFactory:
    def __init__(
        self, error: Exception | None = None, token_error: Exception | None = None
    ) -> None:
        self.error = error
        self.calls = 0
        self.credential = FakeCredential(token_error)

    def __call__(self) -> FakeCredential:
        self.calls += 1
        if self.error is not None:
            raise self.error
        return self.credential


def make_client(
    sdk: FakeSdk | None = None,
    *,
    credentials: FakeCredentialFactory | None = None,
    timeout: float = 5,
    synthesis: "FakeSynthesisSdk | None" = None,
    tts_timeout: float = 5,
) -> tuple[AzureSpeechClient, FakeSdk, FakeCredentialFactory]:
    sdk = sdk or FakeSdk()
    credentials = credentials or FakeCredentialFactory()
    client = AzureSpeechClient(
        region=REGION,
        resource_id=RESOURCE_ID,
        recognition_languages=LANGUAGES,
        stt_timeout_seconds=timeout,
        voice=VOICE,
        tts_timeout_seconds=tts_timeout,
        credential_factory=credentials,
        open_recognition=sdk,
        open_synthesis=synthesis or FakeSynthesisSdk(),
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


def test_the_adapter_receives_pcm_language_region_and_resource_bound_token() -> None:
    client, sdk, credentials = make_client()

    client.transcribe(make_wav(16_000, fill=b"\xab\xcd"))

    [opened] = sdk.opened
    assert set(opened) == {"region", "authorization", "languages", "pcm", "sink"}
    assert opened["pcm"] == b"\xab\xcd" * 16_000  # PCM only, no RIFF header
    assert opened["languages"] == LANGUAGES
    assert opened["region"] == REGION
    assert opened["authorization"] == authorization(1)
    assert credentials.credential.requests == [(ENTRA_SCOPE,)]


def test_invalid_audio_never_touches_the_credential_or_sdk() -> None:
    client, sdk, credentials = make_client()

    with pytest.raises(SpeechInvalidAudioError):
        client.transcribe(b"not a wav")

    assert credentials.calls == 0
    assert credentials.credential.requests == []
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


def test_from_settings_requires_region_and_resource_id() -> None:
    with pytest.raises(SpeechNotConfiguredError):
        AzureSpeechClient.from_settings(Settings(_env_file=None))


def test_from_settings_uses_the_speech_settings() -> None:
    settings = Settings(
        _env_file=None,
        speech_region="swedencentral",
        speech_resource_id=RESOURCE_ID,
        speech_recognition_languages=("es-ES",),
        speech_stt_timeout_seconds=12,
    )

    client = AzureSpeechClient.from_settings(settings)

    assert client._region == "swedencentral"
    assert client._resource_id == RESOURCE_ID
    assert client._recognition_languages == ("es-ES",)
    assert client._stt_timeout_seconds == 12
    assert client._voice == "ca-ES-AlbaNeural"
    assert client._tts_timeout_seconds == 20
    assert client._credential is None


def test_from_settings_defaults_to_the_four_candidate_languages() -> None:
    settings = Settings(_env_file=None, speech_region=REGION, speech_resource_id=RESOURCE_ID)

    client = AzureSpeechClient.from_settings(settings)

    assert client._recognition_languages == ("ca-ES", "es-ES", "en-US", "zh-CN")


def test_the_client_neither_logs_the_languages_nor_the_transcript(
    caplog: pytest.LogCaptureFixture,
) -> None:
    caplog.set_level(logging.DEBUG)
    client, _, _ = make_client(FakeSdk([phrase("private transcript"), END_OF_STREAM, STOPPED]))
    client.transcribe(make_wav())
    with pytest.raises(SpeechNoSpeechError):
        make_client(FakeSdk([END_OF_STREAM, STOPPED]))[0].transcribe(make_wav())

    logged = caplog.text + "".join(str(record.args) for record in caplog.records)
    assert "private transcript" not in logged
    for language in LANGUAGES:
        assert language not in logged


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


@pytest.mark.parametrize("operation", ["transcribe", "synthesize"])
def test_a_failing_token_request_is_a_credential_error(operation: str) -> None:
    synthesis = FakeSynthesisSdk()
    credentials = FakeCredentialFactory(token_error=ValueError("secret azure identity text"))
    client, sdk, _ = make_client(synthesis=synthesis, credentials=credentials)

    with pytest.raises(SpeechUnavailableError) as exc_info:
        if operation == "transcribe":
            client.transcribe(make_wav())
        else:
            client.synthesize("Hola")

    assert exc_info.value.reason == "credential"
    assert exc_info.value.__cause__ is None
    assert "secret" not in str(exc_info.value)
    assert sdk.opened == []
    assert synthesis.opened == []


def test_every_connection_gets_a_fresh_token_from_the_shared_credential() -> None:
    synthesis = FakeSynthesisSdk()
    client, sdk, credentials = make_client(synthesis=synthesis)

    client.transcribe(make_wav())
    client.synthesize("Hola")
    client.transcribe(make_wav())

    assert credentials.calls == 1
    assert credentials.credential.requests == [(ENTRA_SCOPE,)] * 3
    assert [opened["authorization"] for opened in sdk.opened] == [
        authorization(1),
        authorization(3),
    ]
    assert [opened["authorization"] for opened in synthesis.opened] == [authorization(2)]


def test_tokens_are_never_logged_or_exposed(caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.DEBUG)
    synthesis = FakeSynthesisSdk(canceled("BadRequest"))
    client, _, _ = make_client(FakeSdk([cancel("BadRequest"), STOPPED]), synthesis=synthesis)

    errors = []
    for call in (lambda: client.transcribe(make_wav()), lambda: client.synthesize("Hola")):
        with pytest.raises(SpeechUnavailableError) as exc_info:
            call()
        errors.append(exc_info.value)

    logged = caplog.text + "".join(str(record.args) for record in caplog.records)
    rendered = [repr(client), logged] + [
        text for error in errors for text in (str(error), repr(error), repr(vars(error)))
    ]
    for text in rendered:
        assert "secret-token" not in text
        assert "aad#" not in text
        assert "secret-speech-account" not in text


def test_a_native_sdk_that_cannot_load_is_an_sdk_error(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setitem(sys.modules, "app.integrations.speech._sdk", None)  # import fails
    # An earlier import leaves the adapter on its package, where `from ... import`
    # would still find it: remove it too, so nothing can reach the real SDK.
    monkeypatch.delattr(speech_package, "_sdk", raising=False)
    client = AzureSpeechClient(
        region=REGION,
        resource_id=RESOURCE_ID,
        recognition_languages=LANGUAGES,
        stt_timeout_seconds=5,
        voice=VOICE,
        tts_timeout_seconds=5,
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
        f" speech_region='{REGION}', speech_resource_id='{RESOURCE_ID}'))\n"
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
    assert len(credentials.credential.requests) == len(frame_counts)
    assert len({opened["authorization"] for opened in sdk.opened}) == len(frame_counts)
    assert len(sdk.sessions) == len(frame_counts)
    assert len({id(session.sink) for session in sdk.sessions}) == len(frame_counts)


# --- nothing sensitive ------------------------------------------------------------------------


def test_errors_and_client_never_contain_sensitive_values() -> None:
    client, _, _ = make_client()
    assert "secret-speech-account" not in repr(client)

    scripts = [
        [phrase(SECRET_TRANSCRIPT), cancel("Forbidden"), STOPPED],
        [phrase(SECRET_TRANSCRIPT), sleep(5)],
        [END_OF_STREAM, STOPPED],
    ]
    for script in scripts:
        error = failure(FakeSdk(script), timeout=0.2)
        for text in (str(error), repr(error), repr(vars(error))):
            assert "secret-speech-account" not in text
            assert "secret-token" not in text
            assert SECRET_TRANSCRIPT not in text
            assert "\x01\x02" not in text


# ===========================================================================================
# Text-to-speech
# ===========================================================================================

MP3 = b"\xff\xf3\x84\xc4" + bytes(range(256)) * 4  # MP3 frame sync + payload
SECRET_TEXT = "my private reply text"


class Outcome:
    """Stand-in for _sdk.SynthesisOutcome (the client only reads its attributes)."""

    def __init__(self, kind: str, audio: bytes = b"", cancellation: Any = None) -> None:
        self.kind = kind
        self.audio = audio
        self.cancellation = cancellation


def completed(audio: bytes = MP3) -> Outcome:
    return Outcome("completed", audio=audio)


def canceled(code: str | None, session_id: str | None = SESSION_ID) -> Outcome:
    return Outcome("canceled", cancellation=Info(False, code, session_id))


class FakeSynthesisSession:
    def __init__(self, text: str, outcome: Any, **behaviour: Any) -> None:
        self.text = text
        self.outcome = outcome
        self.behaviour = behaviour
        self.calls: list[str] = []
        self.release = threading.Event()

    def synthesize(self) -> Any:
        self.calls.append("synthesize")
        if delay := self.behaviour.get("delay"):
            time.sleep(delay)
        if error := self.behaviour.get("synthesize_error"):
            raise error
        if self.behaviour.get("hang"):
            self.release.wait(10)
        return self.outcome(self.text) if callable(self.outcome) else self.outcome

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


class FakeSynthesisSdk:
    """Stands in for _sdk.open_synthesis; records every call."""

    def __init__(self, outcome: Any = None, **behaviour: Any) -> None:
        self.outcome = outcome if outcome is not None else completed()
        self.behaviour = behaviour
        self.opened: list[dict[str, Any]] = []
        self.sessions: list[FakeSynthesisSession] = []
        self.lock = threading.Lock()

    def __call__(self, **kwargs: Any) -> FakeSynthesisSession:
        if error := self.behaviour.get("open_error"):
            raise error
        behaviour = self.behaviour
        if per_text := self.behaviour.get("per_text"):
            behaviour = {**behaviour, **per_text(kwargs["text"])}
        session = FakeSynthesisSession(kwargs["text"], self.outcome, **behaviour)
        with self.lock:
            self.opened.append(kwargs)
            self.sessions.append(session)
        return session


def synthesize(synthesis: FakeSynthesisSdk, text: str = "Hola", **kwargs: Any) -> bytes:
    client, _, _ = make_client(synthesis=synthesis, **kwargs)
    return client.synthesize(text)


def synthesis_failure(
    synthesis: FakeSynthesisSdk, text: str = "Hola", **kwargs: Any
) -> SpeechError:
    with pytest.raises(SpeechError) as exc_info:
        synthesize(synthesis, text, **kwargs)
    return exc_info.value


# --- input ------------------------------------------------------------------------------------


def test_text_is_trimmed_and_sent_with_voice_region_and_resource_bound_token() -> None:
    synthesis = FakeSynthesisSdk()
    client, _, credentials = make_client(synthesis=synthesis)

    client.synthesize("  Bon dia, sóc Jarvis.\n ")

    [opened] = synthesis.opened
    assert credentials.credential.requests == [(ENTRA_SCOPE,)]
    assert opened == {
        "region": REGION,
        "authorization": authorization(1),
        "voice": VOICE,
        "text": "Bon dia, sóc Jarvis.",
    }


@pytest.mark.parametrize(
    ("text", "reason"),
    [
        ("", "empty"),
        ("   \n\t ", "empty"),
        ("x" * 5001, "too_long"),
        ("🤖" * 5001, "too_long"),
        (None, "invalid_type"),
        (b"bytes text", "invalid_type"),
        (42, "invalid_type"),
        (["Hola"], "invalid_type"),
    ],
)
def test_invalid_text_touches_neither_credential_nor_sdk(text: object, reason: str) -> None:
    synthesis = FakeSynthesisSdk()
    client, _, credentials = make_client(synthesis=synthesis)

    with pytest.raises(SpeechInvalidTextError) as exc_info:
        client.synthesize(text)  # type: ignore[arg-type]

    assert exc_info.value.reason == reason
    assert credentials.calls == 0
    assert synthesis.opened == []


@pytest.mark.parametrize("text", ["x" * 5000, "🤖" * 5000, "  " + "x" * 5000 + "  "])
def test_5000_code_points_are_accepted(text: str) -> None:
    synthesis = FakeSynthesisSdk()

    synthesize(synthesis, text)

    sent = synthesis.opened[0]["text"]
    assert len(sent) == 5000  # Python counts code points: an emoji is one


# --- success --------------------------------------------------------------------------------


def test_the_exact_mp3_bytes_are_returned() -> None:
    audio = synthesize(FakeSynthesisSdk(completed(MP3)))

    assert audio == MP3
    assert isinstance(audio, bytes)


def test_success_closes_but_does_not_stop() -> None:
    synthesis = FakeSynthesisSdk()

    synthesize(synthesis)

    assert synthesis.sessions[0].calls == ["synthesize", "close"]


def test_empty_audio_is_a_bad_response() -> None:
    synthesis = FakeSynthesisSdk(completed(b""))

    error = synthesis_failure(synthesis)

    assert type(error) is SpeechBadResponseError
    assert error.reason == "empty_audio"
    assert synthesis.sessions[0].calls == ["synthesize", "close"]


@pytest.mark.parametrize("outcome", [Outcome("unexpected"), Outcome("canceled", cancellation=None)])
def test_unexpected_results_are_bad_responses(outcome: Outcome) -> None:
    synthesis = FakeSynthesisSdk(outcome)

    error = synthesis_failure(synthesis)

    assert type(error) is SpeechBadResponseError
    assert error.reason == "unexpected_result"
    assert synthesis.sessions[0].calls == ["synthesize", "close"]


# --- cancellations --------------------------------------------------------------------------


@pytest.mark.parametrize(("code", "expected"), EXPECTED.items())
def test_synthesis_cancellations_use_the_shared_mapping(
    code: str | None, expected: tuple[type, str]
) -> None:
    synthesis = FakeSynthesisSdk(canceled(code))

    error = synthesis_failure(synthesis)

    assert type(error) is expected[0]
    assert error.reason == expected[1]
    assert error.code == code if code is not None else error.code is None
    assert error.session_id == SESSION_ID
    assert synthesis.sessions[0].calls == ["synthesize", "close"]


def test_service_timeout_cancellation() -> None:
    error = synthesis_failure(FakeSynthesisSdk(canceled("ServiceTimeout")))

    assert type(error) is SpeechTimeoutError
    assert error.reason == "service_timeout"


# --- failures and cleanup ---------------------------------------------------------------------


def test_synthesis_a_failing_open_is_an_sdk_error() -> None:
    error = synthesis_failure(FakeSynthesisSdk(open_error=OSError("secret native text")))

    assert type(error) is SpeechUnavailableError
    assert error.reason == "sdk_error"
    assert error.__cause__ is None


def test_a_failing_synthesis_is_an_sdk_error_with_best_effort_stop() -> None:
    synthesis = FakeSynthesisSdk(synthesize_error=RuntimeError("secret sdk text"))

    error = synthesis_failure(synthesis)

    assert type(error) is SpeechUnavailableError
    assert error.reason == "sdk_error"
    assert error.__cause__ is None
    assert error.__suppress_context__ is True
    assert synthesis.sessions[0].calls == ["synthesize", "stop", "close"]


def test_a_failing_synthesis_and_a_failing_stop_remain_an_sdk_error() -> None:
    synthesis = FakeSynthesisSdk(
        synthesize_error=RuntimeError("synthesis failed"), stop_error=RuntimeError("stop failed")
    )

    error = synthesis_failure(synthesis)

    assert error.reason == "sdk_error"
    assert synthesis.sessions[0].calls == ["synthesize", "stop", "close"]


def test_timeout_stops_and_closes() -> None:
    synthesis = FakeSynthesisSdk(hang=True)
    started = time.monotonic()

    error = synthesis_failure(synthesis, tts_timeout=0.3)

    elapsed = time.monotonic() - started
    assert type(error) is SpeechTimeoutError
    assert error.reason == "timeout"
    assert 0.3 <= elapsed < 0.3 + 0.3 + 0.4
    assert synthesis.sessions[0].calls == ["synthesize", "stop", "close"]
    synthesis.sessions[0].release.set()


def test_synthesis_timeout_with_a_failing_stop_remains_a_timeout() -> None:
    synthesis = FakeSynthesisSdk(hang=True, stop_error=RuntimeError("stop failed"))

    error = synthesis_failure(synthesis, tts_timeout=0.2)

    assert type(error) is SpeechTimeoutError
    assert error.reason == "timeout"
    synthesis.sessions[0].release.set()


def test_timeout_with_a_hanging_stop_is_bounded_by_the_grace() -> None:
    synthesis = FakeSynthesisSdk(hang=True, hang_stop=True)
    started = time.monotonic()

    error = synthesis_failure(synthesis, tts_timeout=0.2)

    assert error.reason == "timeout"
    assert time.monotonic() - started < 0.2 + 0.3 + 0.4  # deadline + grace + margin
    assert synthesis.sessions[0].calls == ["synthesize", "stop", "close"]
    synthesis.sessions[0].release.set()


@pytest.mark.parametrize(
    ("outcome", "behaviour", "expected"),
    [
        (completed(), {}, None),
        (canceled("TooManyRequests"), {}, "too_many_requests"),
        (completed(b""), {}, "empty_audio"),
        (completed(), {"hang": True}, "timeout"),
        (completed(), {"synthesize_error": RuntimeError("x")}, "sdk_error"),
    ],
)
def test_close_errors_never_replace_the_outcome(
    outcome: Outcome, behaviour: dict[str, Any], expected: str | None
) -> None:
    synthesis = FakeSynthesisSdk(outcome, close_error=RuntimeError("close failed"), **behaviour)

    if expected is None:
        assert synthesize(synthesis, tts_timeout=0.2) == MP3
    else:
        assert synthesis_failure(synthesis, tts_timeout=0.2).reason == expected
    assert synthesis.sessions[0].calls[-1] == "close"
    synthesis.sessions[0].release.set()


def test_success_is_not_delayed_by_the_stop_grace() -> None:
    synthesis = FakeSynthesisSdk(hang_stop=True)  # stop would hang, but is never called
    started = time.monotonic()

    assert synthesize(synthesis) == MP3

    assert time.monotonic() - started < 0.2


def test_a_failing_credential_is_a_credential_error_for_synthesis() -> None:
    synthesis = FakeSynthesisSdk()
    client, _, _ = make_client(
        synthesis=synthesis, credentials=FakeCredentialFactory(error=ValueError("secret"))
    )

    with pytest.raises(SpeechUnavailableError) as exc_info:
        client.synthesize("Hola")

    assert exc_info.value.reason == "credential"
    assert synthesis.opened == []


# --- shared credential ---------------------------------------------------------------------


def test_synthesis_creates_the_credential_once() -> None:
    client, _, credentials = make_client()
    assert credentials.calls == 0

    client.synthesize("Hola")
    client.synthesize("Adéu")

    assert credentials.calls == 1


@pytest.mark.parametrize("order", ["stt-then-tts", "tts-then-stt"])
def test_speech_to_text_and_text_to_speech_share_one_credential(order: str) -> None:
    synthesis = FakeSynthesisSdk()
    client, recognition, credentials = make_client(synthesis=synthesis)

    if order == "stt-then-tts":
        client.transcribe(make_wav())
        client.synthesize("Hola")
    else:
        client.synthesize("Hola")
        client.transcribe(make_wav())

    assert credentials.calls == 1
    # The same fixed path for both: regional endpoint, resource-bound token.
    [stt], [tts] = recognition.opened, synthesis.opened
    assert stt["region"] == tts["region"] == REGION
    assert {stt["authorization"], tts["authorization"]} == {authorization(1), authorization(2)}


# --- concurrency ----------------------------------------------------------------------------


def test_concurrent_syntheses_are_isolated() -> None:
    def per_text(text: str) -> dict[str, Any]:
        return {"hang": True} if text == "slow" else {"delay": 0.05}

    synthesis = FakeSynthesisSdk(lambda text: completed(b"MP3:" + text.encode()), per_text=per_text)
    client, _, credentials = make_client(synthesis=synthesis, tts_timeout=0.5)
    texts = [f"text {i}" for i in range(8)] + ["slow"]
    results: dict[str, object] = {}
    barrier = threading.Barrier(len(texts))

    def run(text: str) -> None:
        barrier.wait()
        try:
            results[text] = client.synthesize(text)
        except SpeechError as error:
            results[text] = error

    threads = [threading.Thread(target=run, args=(text,)) for text in texts]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(10)

    for text in texts[:-1]:
        assert results[text] == b"MP3:" + text.encode()
    assert isinstance(results["slow"], SpeechTimeoutError)
    assert credentials.calls == 1
    assert len(synthesis.sessions) == len(texts)
    for session in synthesis.sessions:
        session.release.set()


# --- nothing sensitive --------------------------------------------------------------------------


def test_synthesis_errors_never_contain_text_audio_resource_or_token() -> None:
    cases = [
        FakeSynthesisSdk(canceled("Forbidden")),
        FakeSynthesisSdk(completed(b"")),
        FakeSynthesisSdk(synthesize_error=RuntimeError(SECRET_TEXT)),
        FakeSynthesisSdk(hang=True),
    ]
    for synthesis in cases:
        error = synthesis_failure(synthesis, SECRET_TEXT, tts_timeout=0.2)
        for text in (str(error), repr(error), repr(vars(error))):
            assert SECRET_TEXT not in text
            assert "secret-speech-account" not in text
            assert "secret-token" not in text
            assert "\\xff\\xf3" not in text
        for session in synthesis.sessions:
            session.release.set()

    # Letters only, so it would also pass the error's code validation if misused.
    for secret in (SECRET_TEXT * 300, "Confidencial" * 500, " ", 42):
        with pytest.raises(SpeechInvalidTextError) as exc_info:
            make_client()[0].synthesize(secret)  # type: ignore[arg-type]
        error = exc_info.value
        rendered = str(error) + repr(error) + repr(vars(error))
        assert SECRET_TEXT not in rendered
        assert "Confidencial" not in rendered
        assert error.code is None
        assert error.session_id is None
