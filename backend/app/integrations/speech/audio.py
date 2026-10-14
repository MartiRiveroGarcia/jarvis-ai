"""WAV validation and PCM extraction for speech-to-text.

Jarvis accepts one audio format: a RIFF/WAVE file with uncompressed, signed 16-bit,
16 kHz, mono PCM. The container is only our transport format: Azure receives the
raw PCM frames, never the RIFF header. Everything happens in memory.
"""

import io
import struct
import wave
from dataclasses import dataclass, field

from app.integrations.speech.errors import SpeechInvalidAudioError

MAX_WAV_BYTES = 1024 * 1024
SAMPLE_RATE = 16_000
SAMPLE_WIDTH_BYTES = 2
CHANNELS = 1
MIN_FRAMES = 4_800  # 0.3 s
MAX_FRAMES = 480_000  # 30 s


@dataclass(frozen=True)
class PcmAudio:
    """Raw 16 kHz, 16-bit, mono PCM frames, without any container header."""

    pcm: bytes = field(repr=False)
    frames: int

    @property
    def duration_seconds(self) -> float:
        return self.frames / SAMPLE_RATE


def parse_wav(data: object) -> PcmAudio:
    """Validate a WAV recording and return its PCM frames.

    Raises SpeechInvalidAudioError (with a reason code only) for anything else.
    """
    if not isinstance(data, bytes | bytearray | memoryview):
        raise SpeechInvalidAudioError(reason="invalid_type")
    raw = bytes(data)
    if len(raw) > MAX_WAV_BYTES:
        raise SpeechInvalidAudioError(reason="too_large")

    try:
        with wave.open(io.BytesIO(raw), "rb") as wav:
            if (
                wav.getnchannels() != CHANNELS
                or wav.getsampwidth() != SAMPLE_WIDTH_BYTES
                or wav.getframerate() != SAMPLE_RATE
                or wav.getcomptype() != "NONE"
            ):
                raise SpeechInvalidAudioError(reason="unsupported_format")
            frames = wav.getnframes()
            pcm = wav.readframes(frames)
    except SpeechInvalidAudioError:
        raise
    except (wave.Error, EOFError, struct.error, ValueError):
        # Not RIFF/WAVE, a missing chunk, a compressed or float format, or a
        # header cut short.
        raise SpeechInvalidAudioError(reason="not_wav") from None

    if len(pcm) != frames * SAMPLE_WIDTH_BYTES:
        raise SpeechInvalidAudioError(reason="truncated")
    if frames < MIN_FRAMES:
        raise SpeechInvalidAudioError(reason="too_short")
    if frames > MAX_FRAMES:
        raise SpeechInvalidAudioError(reason="too_long")
    return PcmAudio(pcm=pcm, frames=frames)
