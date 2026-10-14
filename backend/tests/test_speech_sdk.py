"""Contract tests for the Speech SDK adapter, with the REAL native SDK.

They build real SDK objects with a fake endpoint and a fake credential but never
start recognition, so nothing connects: the credential must receive no token
request (the SDK needs one before any connection) and Python sockets are guarded.
"""

import socket
import time
from typing import Any

import pytest

speechsdk = pytest.importorskip(
    "azure.cognitiveservices.speech", reason="native Azure Speech SDK not loadable"
)

from azure.core.credentials import AccessToken, TokenCredential  # noqa: E402

from app.integrations.speech import _sdk  # noqa: E402

ENDPOINT = "https://jarvis-speech-test.cognitiveservices.azure.com"
PCM = bytes(range(256)) * 250  # 64,000 bytes: two full chunks


class RecordingCredential(TokenCredential):
    def __init__(self) -> None:
        self.requests: list[tuple[str, ...]] = []

    def get_token(self, *scopes: str, **kwargs: Any) -> AccessToken:
        self.requests.append(scopes)
        return AccessToken("fake-token", int(time.time()) + 3600)


class RecordingSink:
    def __init__(self) -> None:
        self.events: list[tuple[str, Any]] = []

    def on_phrase(self, text: str) -> None:
        self.events.append(("phrase", text))

    def on_no_match(self) -> None:
        self.events.append(("no_match", None))

    def on_canceled(self, info: _sdk.CancellationInfo) -> None:
        self.events.append(("canceled", info))

    def on_stopped(self) -> None:
        self.events.append(("stopped", None))


@pytest.fixture(autouse=True)
def no_python_sockets(monkeypatch: pytest.MonkeyPatch) -> None:
    def refuse(*args: Any, **kwargs: Any) -> None:
        raise AssertionError("the Speech adapter must not open connections in tests")

    monkeypatch.setattr(socket.socket, "connect", refuse)
    monkeypatch.setattr(socket, "create_connection", refuse)


@pytest.fixture
def spies(monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
    """Wrap the SDK constructors the adapter uses, recording how they are called."""
    recorded: dict[str, Any] = {"formats": [], "streams": [], "configs": [], "recognizers": []}
    real_format = speechsdk.audio.AudioStreamFormat
    real_stream = speechsdk.audio.PushAudioInputStream
    real_config = speechsdk.SpeechConfig
    real_recognizer = speechsdk.SpeechRecognizer

    # Factories, not subclasses: the SDK's __del__ methods use super(type(self), self),
    # which recurses forever on subclasses.
    def audio_stream_format(**kwargs: Any) -> Any:
        recorded["formats"].append(kwargs)
        return real_format(**kwargs)

    def push_stream(**kwargs: Any) -> Any:
        stream = real_stream(**kwargs)
        stream.writes, stream.closes = [], 0
        real_write, real_close = stream.write, stream.close

        def write(buffer: bytes) -> None:
            stream.writes.append(bytes(buffer))
            real_write(buffer)

        def close() -> None:
            stream.closes += 1
            real_close()

        stream.write, stream.close = write, close
        recorded["streams"].append(stream)
        return stream

    def speech_config(**kwargs: Any) -> Any:
        config = real_config(**kwargs)
        recorded["configs"].append((kwargs, config))
        return config

    def speech_recognizer(**kwargs: Any) -> Any:
        recognizer = real_recognizer(**kwargs)
        recorded["recognizers"].append(recognizer)
        return recognizer

    monkeypatch.setattr(speechsdk.audio, "AudioStreamFormat", audio_stream_format)
    monkeypatch.setattr(speechsdk.audio, "PushAudioInputStream", push_stream)
    monkeypatch.setattr(speechsdk, "SpeechConfig", speech_config)
    monkeypatch.setattr(speechsdk, "SpeechRecognizer", speech_recognizer)
    return recorded


def open_session(credential: TokenCredential | None = None) -> tuple[Any, RecordingCredential]:
    credential = credential or RecordingCredential()
    session = _sdk.open_recognition(
        endpoint=ENDPOINT, credential=credential, language="ca-ES", pcm=PCM, sink=RecordingSink()
    )
    return session, credential


# --- construction ------------------------------------------------------------------------


def test_audio_format_is_explicit_16khz_16bit_mono(spies: dict[str, Any]) -> None:
    session, _ = open_session()

    assert spies["formats"] == [
        {"samples_per_second": 16_000, "bits_per_sample": 16, "channels": 1}
    ]
    session.close()


def test_only_the_pcm_is_written_in_chunks_then_the_stream_is_closed(
    spies: dict[str, Any],
) -> None:
    session, _ = open_session()

    [stream] = spies["streams"]
    assert b"".join(stream.writes) == PCM
    assert [len(chunk) for chunk in stream.writes] == [32_000, 32_000]
    assert stream.closes == 1
    session.close()


def test_config_uses_the_credential_the_custom_endpoint_and_the_language(
    spies: dict[str, Any],
) -> None:
    credential = RecordingCredential()
    session, _ = open_session(credential)

    [(kwargs, config)] = spies["configs"]
    assert kwargs == {"token_credential": credential, "endpoint": ENDPOINT + "/"}
    assert config.token_credential is credential
    assert config.speech_recognition_language == "ca-ES"
    assert config.get_property(speechsdk.PropertyId.SpeechServiceConnection_Endpoint) == (
        ENDPOINT + "/"
    )
    # No key or region authentication is configured.
    assert config.get_property(speechsdk.PropertyId.SpeechServiceConnection_Key) == ""
    assert config.get_property(speechsdk.PropertyId.SpeechServiceConnection_Region) == ""
    session.close()


def test_construction_requests_no_token_and_opens_no_connection(spies: dict[str, Any]) -> None:
    session, credential = open_session()
    time.sleep(0.3)  # give any background activity a chance to show up

    assert credential.requests == []
    session.close()


def test_handlers_are_connected_and_close_disconnects_them(spies: dict[str, Any]) -> None:
    session, _ = open_session()
    [recognizer] = spies["recognizers"]
    signals = [recognizer.recognized, recognizer.canceled, recognizer.session_stopped]
    assert all(signal.is_connected() for signal in signals)

    session.close()

    assert not any(signal.is_connected() for signal in signals)
    assert session._recognizer is None
    assert session._stream is None


def test_close_is_idempotent_and_never_raises(spies: dict[str, Any]) -> None:
    session, _ = open_session()

    session.close()
    session.close()

    session.stop()  # after close: nothing to stop, no error


# --- event translation ---------------------------------------------------------------------


class Result:
    def __init__(self, reason: Any, text: str = "") -> None:
        self.reason = reason
        self.text = text


class Details:
    def __init__(self, reason: Any, code: Any) -> None:
        self.reason = reason
        self.code = code

    @property
    def error_details(self) -> str:
        raise AssertionError("error_details must never be read")


class Event:
    def __init__(self, *, result: Any = None, details: Any = None, session_id: Any = "s1") -> None:
        self.result = result
        self.cancellation_details = details
        self.session_id = session_id


def test_recognized_speech_becomes_a_phrase() -> None:
    sink = RecordingSink()

    _sdk.translate_recognized(
        Event(result=Result(speechsdk.ResultReason.RecognizedSpeech, "Bon dia")), sink
    )

    assert sink.events == [("phrase", "Bon dia")]


def test_no_match_is_reported_and_other_reasons_ignored() -> None:
    sink = RecordingSink()

    _sdk.translate_recognized(Event(result=Result(speechsdk.ResultReason.NoMatch)), sink)
    _sdk.translate_recognized(Event(result=Result(speechsdk.ResultReason.RecognizingSpeech)), sink)

    assert sink.events == [("no_match", None)]


@pytest.mark.parametrize(
    ("reason", "end_of_stream"),
    [
        (speechsdk.CancellationReason.EndOfStream, True),
        (speechsdk.CancellationReason.CancelledByUser, True),
        (speechsdk.CancellationReason.Error, False),
    ],
)
def test_cancellation_reasons(reason: Any, end_of_stream: bool) -> None:
    info = _sdk.cancellation_info(
        Event(details=Details(reason, speechsdk.CancellationErrorCode.NoError))
    )

    assert info.end_of_stream is end_of_stream


@pytest.mark.parametrize("code", list(speechsdk.CancellationErrorCode))
def test_every_cancellation_code_becomes_its_name(code: Any) -> None:
    info = _sdk.cancellation_info(
        Event(details=Details(speechsdk.CancellationReason.Error, code), session_id="abc-123")
    )

    assert info == _sdk.CancellationInfo(end_of_stream=False, code=code.name, session_id="abc-123")


def test_an_unknown_code_becomes_none() -> None:
    info = _sdk.cancellation_info(
        Event(details=Details(speechsdk.CancellationReason.Error, 999), session_id=None)
    )

    assert info.code is None
    assert info.session_id is None


def test_guarded_callbacks_never_raise_into_the_sdk() -> None:
    def explode(_evt: Any) -> None:
        raise RuntimeError("must not escape")

    _sdk._guarded(explode)(object())  # no exception
