"""Thin adapter around the native Azure Speech SDK.

The ONLY module that imports azure.cognitiveservices.speech, and it is itself
imported lazily by the client on first use, so neither app startup nor importing
app.integrations.speech loads the native library.

It turns SDK events into calls on a RecognitionSink with small, content-safe
values. It never reads the SDK's cancellation error details.
"""

from collections.abc import Callable
from contextlib import suppress
from dataclasses import dataclass
from typing import Any, Protocol

import azure.cognitiveservices.speech as speechsdk
from azure.core.credentials import TokenCredential

SAMPLE_RATE = 16_000
BITS_PER_SAMPLE = 16
CHANNELS = 1
PCM_CHUNK_BYTES = 32_000  # one second of 16 kHz, 16-bit mono audio


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


def open_recognition(
    *,
    endpoint: str,
    credential: TokenCredential,
    language: str,
    pcm: bytes,
    sink: RecognitionSink,
) -> RecognitionSession:
    """Prepare continuous recognition of [pcm]. Connects nothing until start()."""
    stream_format = speechsdk.audio.AudioStreamFormat(
        samples_per_second=SAMPLE_RATE, bits_per_sample=BITS_PER_SAMPLE, channels=CHANNELS
    )
    stream = speechsdk.audio.PushAudioInputStream(stream_format=stream_format)
    # Microsoft Entra ID: the SDK requests and refreshes tokens from the credential.
    config = speechsdk.SpeechConfig(token_credential=credential, endpoint=endpoint + "/")
    config.speech_recognition_language = language
    recognizer = speechsdk.SpeechRecognizer(
        speech_config=config, audio_config=speechsdk.audio.AudioConfig(stream=stream)
    )
    recognizer.recognized.connect(_guarded(lambda evt: translate_recognized(evt, sink)))
    recognizer.canceled.connect(_guarded(lambda evt: sink.on_canceled(cancellation_info(evt))))
    recognizer.session_stopped.connect(_guarded(lambda _evt: sink.on_stopped()))

    # Only raw PCM frames; closing the stream ends recognition after the last frame.
    for offset in range(0, len(pcm), PCM_CHUNK_BYTES):
        stream.write(pcm[offset : offset + PCM_CHUNK_BYTES])
    stream.close()
    return _SdkRecognitionSession(recognizer, stream)


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
