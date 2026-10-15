"""Thin adapter around the native Azure Speech SDK.

The ONLY module that imports azure.cognitiveservices.speech, and it is itself
imported lazily by the client on first use, so neither app startup nor importing
app.integrations.speech loads the native library.

It turns SDK events and results into small, content-safe values: calls on a
RecognitionSink for speech-to-text and a SynthesisOutcome for text-to-speech. It
never reads the SDK's cancellation error details.
"""

from collections.abc import Callable, Sequence
from contextlib import suppress
from dataclasses import dataclass, field
from typing import Any, Literal, Protocol

import azure.cognitiveservices.speech as speechsdk
from azure.core.credentials import TokenCredential

SAMPLE_RATE = 16_000
BITS_PER_SAMPLE = 16
CHANNELS = 1
PCM_CHUNK_BYTES = 32_000  # one second of 16 kHz, 16-bit mono audio
# Identify the language once, at the start of the recording: one utterance per request.
LANGUAGE_ID_MODE = "AtStart"


@dataclass(frozen=True)
class CancellationInfo:
    end_of_stream: bool  # the audio ended or recognition was stopped: not an error
    code: str | None  # CancellationErrorCode name, e.g. "TooManyRequests"
    session_id: str | None


class RecognitionSink(Protocol):
    def on_phrase(self, text: str) -> None: ...
    def on_no_match(self) -> None: ...
    def on_canceled(self, info: CancellationInfo) -> None: ...
    def on_stopped(self) -> None: ...


class RecognitionSession(Protocol):
    def start(self) -> None: ...
    def stop(self) -> None: ...
    def close(self) -> None: ...


@dataclass(frozen=True)
class SynthesisOutcome:
    kind: Literal["completed", "canceled", "unexpected"]
    audio: bytes = field(default=b"", repr=False)  # only for "completed"
    cancellation: CancellationInfo | None = None  # only for "canceled"


class SynthesisSession(Protocol):
    def synthesize(self) -> SynthesisOutcome: ...
    def stop(self) -> None: ...
    def close(self) -> None: ...


def _speech_config(endpoint: str, credential: TokenCredential) -> Any:
    # Microsoft Entra ID: the SDK requests and refreshes tokens from the credential.
    return speechsdk.SpeechConfig(token_credential=credential, endpoint=endpoint + "/")


def open_recognition(
    *,
    endpoint: str,
    credential: TokenCredential,
    languages: Sequence[str],
    pcm: bytes,
    sink: RecognitionSink,
) -> RecognitionSession:
    """Prepare continuous recognition of [pcm]. Connects nothing until start().

    One language: fixed-language recognition. Several: the service identifies which
    one is spoken at the start, in the same request. The result is never read here.
    """
    stream_format = speechsdk.audio.AudioStreamFormat(
        samples_per_second=SAMPLE_RATE, bits_per_sample=BITS_PER_SAMPLE, channels=CHANNELS
    )
    stream = speechsdk.audio.PushAudioInputStream(stream_format=stream_format)
    config = _speech_config(endpoint, credential)
    audio_config = speechsdk.audio.AudioConfig(stream=stream)
    if len(languages) == 1:
        config.speech_recognition_language = languages[0]
        recognizer = speechsdk.SpeechRecognizer(speech_config=config, audio_config=audio_config)
    else:
        # The recognizer must carry no fixed language as well: the SDK accepts both
        # silently.
        config.set_property(
            speechsdk.PropertyId.SpeechServiceConnection_LanguageIdMode, LANGUAGE_ID_MODE
        )
        recognizer = speechsdk.SpeechRecognizer(
            speech_config=config,
            audio_config=audio_config,
            auto_detect_source_language_config=speechsdk.languageconfig.AutoDetectSourceLanguageConfig(
                languages=list(languages)
            ),
        )
    recognizer.recognized.connect(_guarded(lambda evt: translate_recognized(evt, sink)))
    recognizer.canceled.connect(_guarded(lambda evt: sink.on_canceled(cancellation_info(evt))))
    recognizer.session_stopped.connect(_guarded(lambda _evt: sink.on_stopped()))

    # Only raw PCM frames; closing the stream ends recognition after the last frame.
    for offset in range(0, len(pcm), PCM_CHUNK_BYTES):
        stream.write(pcm[offset : offset + PCM_CHUNK_BYTES])
    stream.close()
    return _SdkRecognitionSession(recognizer, stream)


def open_synthesis(
    *,
    endpoint: str,
    credential: TokenCredential,
    voice: str,
    text: str,
) -> SynthesisSession:
    """Prepare plain-text synthesis of [text]. Connects nothing until synthesize()."""
    config = _speech_config(endpoint, credential)
    config.speech_synthesis_voice_name = voice
    config.set_speech_synthesis_output_format(
        speechsdk.SpeechSynthesisOutputFormat.Audio24Khz48KBitRateMonoMp3
    )
    # audio_config=None is required: the SDK default plays on the default speaker.
    # With None, the audio exists only in the result, in memory.
    synthesizer = speechsdk.SpeechSynthesizer(speech_config=config, audio_config=None)
    return _SdkSynthesisSession(synthesizer, text)


def synthesis_outcome(result: Any) -> SynthesisOutcome:
    if result.reason == speechsdk.ResultReason.SynthesizingAudioCompleted:
        return SynthesisOutcome("completed", audio=bytes(result.audio_data or b""))
    if result.reason == speechsdk.ResultReason.Canceled:
        details = result.cancellation_details  # only .reason and .error_code are read
        code = details.error_code
        return SynthesisOutcome(
            "canceled",
            cancellation=CancellationInfo(
                end_of_stream=False,
                code=code.name if isinstance(code, speechsdk.CancellationErrorCode) else None,
                session_id=getattr(result, "result_id", None),
            ),
        )
    return SynthesisOutcome("unexpected")


def translate_recognized(evt: Any, sink: RecognitionSink) -> None:
    result = evt.result
    if result.reason == speechsdk.ResultReason.RecognizedSpeech:
        sink.on_phrase(result.text)
    elif result.reason == speechsdk.ResultReason.NoMatch:
        sink.on_no_match()


def cancellation_info(evt: Any) -> CancellationInfo:
    details = evt.cancellation_details  # only .reason and .code are read
    code = details.code
    return CancellationInfo(
        end_of_stream=details.reason
        in (speechsdk.CancellationReason.EndOfStream, speechsdk.CancellationReason.CancelledByUser),
        code=code.name if isinstance(code, speechsdk.CancellationErrorCode) else None,
        session_id=getattr(evt, "session_id", None),
    )


def _guarded(handler: Callable[[Any], None]) -> Callable[[Any], None]:
    """SDK callbacks run on native threads: never let an exception escape into them."""

    def callback(evt: Any) -> None:
        with suppress(Exception):  # nothing safe to report from a native callback
            handler(evt)

    return callback


class _SdkRecognitionSession:
    def __init__(self, recognizer: Any, stream: Any) -> None:
        self._recognizer = recognizer
        self._stream = stream
        self._closed = False

    def start(self) -> None:
        self._recognizer.start_continuous_recognition_async().get()

    def stop(self) -> None:
        recognizer = self._recognizer
        if recognizer is not None:
            recognizer.stop_continuous_recognition_async().get()

    def close(self) -> None:
        """Disconnect every handler and release the SDK objects. Idempotent; never raises."""
        if self._closed:
            return
        self._closed = True
        recognizer, self._recognizer = self._recognizer, None
        stream, self._stream = self._stream, None
        if recognizer is not None:
            for signal in (recognizer.recognized, recognizer.canceled, recognizer.session_stopped):
                with suppress(Exception):
                    signal.disconnect_all()
        if stream is not None:
            with suppress(Exception):
                stream.close()


class _SdkSynthesisSession:
    def __init__(self, synthesizer: Any, text: str) -> None:
        self._synthesizer = synthesizer
        self._text = text
        self._closed = False

    def synthesize(self) -> SynthesisOutcome:
        return synthesis_outcome(self._synthesizer.speak_text_async(self._text).get())

    def stop(self) -> None:
        synthesizer = self._synthesizer
        if synthesizer is not None:
            synthesizer.stop_speaking_async().get()

    def close(self) -> None:
        """Release the SDK objects and the text. Idempotent; never raises."""
        if self._closed:
            return
        self._closed = True
        self._synthesizer = None
        self._text = ""
