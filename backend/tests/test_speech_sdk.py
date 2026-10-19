"""Contract tests for the Speech SDK adapter, with the REAL native SDK.

They build real SDK objects with a fake region and a fake resource-bound token but
never start recognition or synthesis, so nothing connects; Python sockets are guarded.
"""

import socket
from typing import Any

import pytest

speechsdk = pytest.importorskip(
    "azure.cognitiveservices.speech", reason="native Azure Speech SDK not loadable"
)

from app.integrations.speech import _sdk  # noqa: E402

REGION = "swedencentral"
AUTHORIZATION = (
    "aad#/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg"
    "/providers/Microsoft.CognitiveServices/accounts/jarvis-speech-test#fake-token"
)
PCM = bytes(range(256)) * 250  # 64,000 bytes: two full chunks
LANGUAGES = ("ca-ES", "es-ES", "en-US", "zh-CN")


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
    recorded: dict[str, Any] = {
        "formats": [],
        "streams": [],
        "configs": [],
        "recognizers": [],
        "recognizer_kwargs": [],
        "auto_detect": [],
        "synthesizers": [],
        "output_formats": [],
    }
    real_format = speechsdk.audio.AudioStreamFormat
    real_stream = speechsdk.audio.PushAudioInputStream
    real_config = speechsdk.SpeechConfig
    real_recognizer = speechsdk.SpeechRecognizer
    real_synthesizer = speechsdk.SpeechSynthesizer
    real_auto_detect = speechsdk.languageconfig.AutoDetectSourceLanguageConfig

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
        real_set_format = config.set_speech_synthesis_output_format

        def set_output_format(format_id: Any) -> None:
            recorded["output_formats"].append(format_id)
            real_set_format(format_id)

        config.set_speech_synthesis_output_format = set_output_format
        recorded["configs"].append((kwargs, config))
        return config

    def speech_synthesizer(**kwargs: Any) -> Any:
        synthesizer = real_synthesizer(**kwargs)
        recorded["synthesizers"].append((kwargs, synthesizer))
        return synthesizer

    def speech_recognizer(**kwargs: Any) -> Any:
        recognizer = real_recognizer(**kwargs)
        recorded["recognizers"].append(recognizer)
        recorded["recognizer_kwargs"].append(kwargs)
        return recognizer

    def auto_detect(**kwargs: Any) -> Any:
        recorded["auto_detect"].append(kwargs)
        return real_auto_detect(**kwargs)

    monkeypatch.setattr(speechsdk.audio, "AudioStreamFormat", audio_stream_format)
    monkeypatch.setattr(speechsdk.audio, "PushAudioInputStream", push_stream)
    monkeypatch.setattr(speechsdk, "SpeechConfig", speech_config)
    monkeypatch.setattr(speechsdk, "SpeechRecognizer", speech_recognizer)
    monkeypatch.setattr(speechsdk, "SpeechSynthesizer", speech_synthesizer)
    monkeypatch.setattr(speechsdk.languageconfig, "AutoDetectSourceLanguageConfig", auto_detect)
    return recorded


def open_session(languages: tuple[str, ...] = ("ca-ES",)) -> Any:
    return _sdk.open_recognition(
        region=REGION,
        authorization=AUTHORIZATION,
        languages=languages,
        pcm=PCM,
        sink=RecordingSink(),
    )


def assert_regional_entra_config(kwargs: dict[str, Any], config: Any) -> None:
    """The configuration that works: regional endpoint, resource-bound Entra token."""
    assert kwargs == {"auth_token": AUTHORIZATION, "region": REGION}
    assert config.authorization_token == AUTHORIZATION
    assert config.region == REGION
    # Never the custom-domain endpoint, a host, a key or a credential-managed token.
    assert config.get_property(speechsdk.PropertyId.SpeechServiceConnection_Endpoint) == ""
    assert config.get_property(speechsdk.PropertyId.SpeechServiceConnection_Host) == ""
    assert config.get_property(speechsdk.PropertyId.SpeechServiceConnection_Key) == ""
    assert config.token_credential is None


def recognizer_property(recognizer: Any, name: str) -> str:
    return recognizer.properties.get_property(getattr(speechsdk.PropertyId, name))


BOTH_PATHS = pytest.mark.parametrize("languages", [("ca-ES",), LANGUAGES], ids=["one", "four"])


# --- construction ------------------------------------------------------------------------


@BOTH_PATHS
def test_audio_format_is_explicit_16khz_16bit_mono(
    spies: dict[str, Any], languages: tuple[str, ...]
) -> None:
    session = open_session(languages=languages)

    assert spies["formats"] == [
        {"samples_per_second": 16_000, "bits_per_sample": 16, "channels": 1}
    ]
    session.close()


@BOTH_PATHS
def test_only_the_pcm_is_written_in_chunks_then_the_stream_is_closed(
    spies: dict[str, Any], languages: tuple[str, ...]
) -> None:
    session = open_session(languages=languages)

    [stream] = spies["streams"]
    assert b"".join(stream.writes) == PCM
    assert [len(chunk) for chunk in stream.writes] == [32_000, 32_000]
    assert stream.closes == 1
    session.close()


def test_config_uses_the_region_the_resource_bound_token_and_the_language(
    spies: dict[str, Any],
) -> None:
    session = open_session()

    [(kwargs, config)] = spies["configs"]
    assert_regional_entra_config(kwargs, config)
    assert config.speech_recognition_language == "ca-ES"
    session.close()


@BOTH_PATHS
def test_handlers_are_connected_and_close_disconnects_them(
    spies: dict[str, Any], languages: tuple[str, ...]
) -> None:
    session = open_session(languages=languages)
    [recognizer] = spies["recognizers"]
    signals = [recognizer.recognized, recognizer.canceled, recognizer.session_stopped]
    assert all(signal.is_connected() for signal in signals)

    session.close()

    assert not any(signal.is_connected() for signal in signals)
    assert session._recognizer is None
    assert session._stream is None


def test_one_language_is_fixed_recognition_without_identification(
    spies: dict[str, Any],
) -> None:
    session = open_session(languages=("es-ES",))

    [(_, config)] = spies["configs"]
    [kwargs] = spies["recognizer_kwargs"]
    [recognizer] = spies["recognizers"]
    assert config.speech_recognition_language == "es-ES"
    assert spies["auto_detect"] == []
    assert "auto_detect_source_language_config" not in kwargs
    assert (
        recognizer_property(recognizer, "SpeechServiceConnection_AutoDetectSourceLanguages") == ""
    )
    assert recognizer_property(recognizer, "SpeechServiceConnection_LanguageIdMode") == ""
    session.close()


def test_several_languages_are_identified_at_start_among_exactly_the_candidates(
    spies: dict[str, Any],
) -> None:
    session = open_session(languages=LANGUAGES)

    assert spies["auto_detect"] == [{"languages": ["ca-ES", "es-ES", "en-US", "zh-CN"]}]
    [kwargs] = spies["recognizer_kwargs"]
    assert set(kwargs) == {"speech_config", "audio_config", "auto_detect_source_language_config"}
    # Read back from the real native recognizer.
    [recognizer] = spies["recognizers"]
    assert (
        recognizer_property(recognizer, "SpeechServiceConnection_AutoDetectSourceLanguages")
        == "ca-ES,es-ES,en-US,zh-CN"
    )
    assert recognizer_property(recognizer, "SpeechServiceConnection_LanguageIdMode") == "AtStart"
    session.close()


def test_several_languages_leave_no_fixed_recognition_language(spies: dict[str, Any]) -> None:
    # The SDK silently accepts a fixed language next to identification.
    session = open_session(languages=LANGUAGES)

    [(_, config)] = spies["configs"]
    [recognizer] = spies["recognizers"]
    assert config.speech_recognition_language == ""
    assert recognizer_property(recognizer, "SpeechServiceConnection_RecoLanguage") == ""
    session.close()


def test_identification_keeps_the_regional_entra_config(spies: dict[str, Any]) -> None:
    session = open_session(languages=LANGUAGES)

    [(kwargs, config)] = spies["configs"]
    assert_regional_entra_config(kwargs, config)
    session.close()


def test_close_is_idempotent_and_never_raises(spies: dict[str, Any]) -> None:
    session = open_session()

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


# ===========================================================================================
# Text-to-speech
# ===========================================================================================


def open_synthesis() -> Any:
    return _sdk.open_synthesis(
        region=REGION, authorization=AUTHORIZATION, voice="ca-ES-AlbaNeural", text="Hola"
    )


def test_synthesis_config_uses_the_region_and_the_resource_bound_token(
    spies: dict[str, Any],
) -> None:
    session = open_synthesis()

    [(kwargs, config)] = spies["configs"]
    assert_regional_entra_config(kwargs, config)
    session.close()


def test_synthesis_voice_and_mp3_output_format(spies: dict[str, Any]) -> None:
    session = open_synthesis()

    [(_, config)] = spies["configs"]
    assert config.speech_synthesis_voice_name == "ca-ES-AlbaNeural"
    assert spies["output_formats"] == [
        speechsdk.SpeechSynthesisOutputFormat.Audio24Khz48KBitRateMonoMp3
    ]
    assert config.speech_synthesis_output_format_string == "audio-24khz-48kbitrate-mono-mp3"
    session.close()


def test_the_synthesizer_has_no_audio_output_device(spies: dict[str, Any]) -> None:
    session = open_synthesis()

    [(kwargs, _synthesizer)] = spies["synthesizers"]
    # Passed explicitly: the SDK default would play on the default speaker.
    assert "audio_config" in kwargs
    assert kwargs["audio_config"] is None
    session.close()


def test_synthesis_close_releases_references_and_is_idempotent(spies: dict[str, Any]) -> None:
    session = open_synthesis()

    session.close()
    session.close()

    assert session._synthesizer is None
    assert session._text == ""
    session.stop()  # after close: nothing to stop, no error


class SynthesisDetails:
    """Synthesis cancellation details: .reason and .error_code (no .code)."""

    def __init__(self, reason: Any, error_code: Any) -> None:
        self.reason = reason
        self.error_code = error_code

    @property
    def error_details(self) -> str:
        raise AssertionError("error_details must never be read")


class SynthesisResult:
    def __init__(
        self,
        reason: Any,
        audio_data: bytes | None = None,
        details: Any = None,
        result_id: Any = "abc-123",
    ) -> None:
        self.reason = reason
        self.audio_data = audio_data
        self.cancellation_details = details
        self.result_id = result_id


def test_completed_synthesis_returns_the_exact_audio() -> None:
    audio = b"\xff\xf3" + bytes(range(256))

    outcome = _sdk.synthesis_outcome(
        SynthesisResult(speechsdk.ResultReason.SynthesizingAudioCompleted, audio)
    )

    assert outcome.kind == "completed"
    assert outcome.audio == audio
    assert outcome.cancellation is None


def test_completed_synthesis_without_audio_data_has_empty_audio() -> None:
    outcome = _sdk.synthesis_outcome(
        SynthesisResult(speechsdk.ResultReason.SynthesizingAudioCompleted, None)
    )

    assert outcome == _sdk.SynthesisOutcome("completed", audio=b"")


@pytest.mark.parametrize("code", list(speechsdk.CancellationErrorCode))
def test_canceled_synthesis_uses_error_code_and_result_id(code: Any) -> None:
    outcome = _sdk.synthesis_outcome(
        SynthesisResult(
            speechsdk.ResultReason.Canceled,
            details=SynthesisDetails(speechsdk.CancellationReason.Error, code),
            result_id="abc-123",
        )
    )

    assert outcome == _sdk.SynthesisOutcome(
        "canceled",
        cancellation=_sdk.CancellationInfo(
            end_of_stream=False, code=code.name, session_id="abc-123"
        ),
    )


def test_canceled_synthesis_with_an_unknown_code() -> None:
    outcome = _sdk.synthesis_outcome(
        SynthesisResult(
            speechsdk.ResultReason.Canceled,
            details=SynthesisDetails(speechsdk.CancellationReason.Error, 999),
            result_id=None,
        )
    )

    assert outcome.cancellation == _sdk.CancellationInfo(
        end_of_stream=False, code=None, session_id=None
    )


@pytest.mark.parametrize(
    "reason",
    [
        speechsdk.ResultReason.SynthesizingAudio,
        speechsdk.ResultReason.SynthesizingAudioStarted,
        speechsdk.ResultReason.RecognizedSpeech,
    ],
)
def test_other_synthesis_results_are_unexpected(reason: Any) -> None:
    outcome = _sdk.synthesis_outcome(SynthesisResult(reason, b"partial"))

    assert outcome == _sdk.SynthesisOutcome("unexpected")


def test_synthesis_outcome_hides_the_audio_from_repr() -> None:
    outcome = _sdk.SynthesisOutcome("completed", audio=b"SECRET-MP3-BYTES")

    assert "SECRET-MP3-BYTES" not in repr(outcome)


class StandInSynthesizer:
    """Records which synthesis methods the session calls; returns a ready future."""

    def __init__(self, result: Any) -> None:
        self.result = result
        self.calls: list[tuple[str, Any]] = []

    def speak_text_async(self, text: str) -> Any:
        self.calls.append(("speak_text_async", text))
        return _Future(self.result)

    def speak_ssml_async(self, ssml: str) -> Any:
        raise AssertionError("SSML must never be used")

    def stop_speaking_async(self) -> Any:
        self.calls.append(("stop_speaking_async", None))
        return _Future(None)


class _Future:
    def __init__(self, value: Any) -> None:
        self.value = value

    def get(self) -> Any:
        return self.value


def test_session_synthesizes_plain_text_and_translates_the_result() -> None:
    synthesizer = StandInSynthesizer(
        SynthesisResult(speechsdk.ResultReason.SynthesizingAudioCompleted, b"MP3")
    )
    session = _sdk._SdkSynthesisSession(synthesizer, "Hola, sóc Jarvis.")

    outcome = session.synthesize()

    assert synthesizer.calls == [("speak_text_async", "Hola, sóc Jarvis.")]
    assert outcome == _sdk.SynthesisOutcome("completed", audio=b"MP3")


def test_session_stop_uses_stop_speaking() -> None:
    synthesizer = StandInSynthesizer(None)
    session = _sdk._SdkSynthesisSession(synthesizer, "Hola")

    session.stop()

    assert synthesizer.calls == [("stop_speaking_async", None)]
