"""WAV validation and PCM extraction: pure Python, no Speech SDK."""

import io
import struct
import wave

import pytest

from app.integrations.speech import audio as audio_module
from app.integrations.speech.audio import (
    MAX_FRAMES,
    MAX_WAV_BYTES,
    MIN_FRAMES,
    PcmAudio,
    parse_wav,
)
from app.integrations.speech.errors import SpeechInvalidAudioError


def make_wav(
    frames: int = 16_000,
    *,
    rate: int = 16_000,
    width: int = 2,
    channels: int = 1,
    fill: bytes = b"\x01\x02",
) -> bytes:
    """A WAV file built in memory. The PCM is a repeated pattern, easy to recognise."""
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(width)
        wav.setframerate(rate)
        frame = (fill * width)[:width] * channels
        wav.writeframes(frame * frames)
    return buffer.getvalue()


def with_format_tag(wav_bytes: bytes, tag: int) -> bytes:
    """Rewrite the fmt chunk's audio format tag (1 = PCM)."""
    index = wav_bytes.index(b"fmt ") + 8
    return wav_bytes[:index] + struct.pack("<H", tag) + wav_bytes[index + 2 :]


def reason_for(data: object) -> str:
    with pytest.raises(SpeechInvalidAudioError) as exc_info:
        parse_wav(data)
    return exc_info.value.reason


# --- valid input ----------------------------------------------------------------------


def test_valid_wav_returns_only_the_pcm_frames() -> None:
    wav_bytes = make_wav(16_000, fill=b"\xab\xcd")

    audio = parse_wav(wav_bytes)

    assert audio.frames == 16_000
    assert audio.duration_seconds == 1.0
    assert audio.pcm == b"\xab\xcd" * 16_000
    assert len(audio.pcm) == audio.frames * 2
    # No container bytes are passed on.
    for marker in (b"RIFF", b"WAVE", b"fmt ", b"data"):
        assert marker not in audio.pcm
    assert len(audio.pcm) < len(wav_bytes)


@pytest.mark.parametrize("wrap", [bytes, bytearray, memoryview])
def test_bytes_like_inputs_are_accepted(wrap: type) -> None:
    assert parse_wav(wrap(make_wav())).frames == 16_000


def test_extra_chunks_after_the_data_are_ignored() -> None:
    wav_bytes = make_wav(8_000)
    riff_size = struct.unpack("<I", wav_bytes[4:8])[0]
    extra = b"LIST" + struct.pack("<I", 4) + b"INFO"
    patched = wav_bytes[:4] + struct.pack("<I", riff_size + len(extra)) + wav_bytes[8:] + extra

    assert parse_wav(patched).pcm == b"\x01\x02" * 8_000


def test_pcm_is_hidden_from_repr() -> None:
    audio = PcmAudio(pcm=b"secret-audio", frames=6)

    assert "secret-audio" not in repr(audio)


# --- duration -------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("frames", "reason"),
    [
        (0, "too_short"),
        (MIN_FRAMES - 1, "too_short"),
        (MIN_FRAMES, None),
        (MAX_FRAMES, None),
        (MAX_FRAMES + 1, "too_long"),
    ],
)
def test_duration_boundaries(frames: int, reason: str | None) -> None:
    wav_bytes = make_wav(frames)
    if reason is None:
        assert parse_wav(wav_bytes).frames == frames
    else:
        assert reason_for(wav_bytes) == reason


def test_duration_limits_are_0_3_and_30_seconds() -> None:
    assert MIN_FRAMES / 16_000 == 0.3
    assert MAX_FRAMES / 16_000 == 30.0
    # The longest valid file fits within the byte limit.
    assert len(make_wav(MAX_FRAMES)) <= MAX_WAV_BYTES


# --- format ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "kwargs",
    [
        {"channels": 2},
        {"width": 1},
        {"width": 3},
        {"width": 4},
        {"rate": 8_000},
        {"rate": 22_050},
        {"rate": 44_100},
        {"rate": 48_000},
    ],
)
def test_unsupported_pcm_formats_are_rejected(kwargs: dict[str, int]) -> None:
    assert reason_for(make_wav(8_000, **kwargs)) == "unsupported_format"


@pytest.mark.parametrize("tag", [3, 6, 7, 0x55])  # float, A-law, mu-law, MP3
def test_compressed_or_float_formats_are_rejected(tag: int) -> None:
    assert reason_for(with_format_tag(make_wav(8_000), tag)) == "not_wav"


@pytest.mark.parametrize(
    "data",
    [
        b"",
        b"not audio at all",
        b"ID3\x04\x00\x00\x00\x00\x00\x00" + b"\x00" * 100,  # MP3
        b"OggS" + b"\x00" * 100,
        b"RIFF\x24\x00\x00\x00AVI " + b"\x00" * 100,
        bytes(range(256)) * 4,
    ],
)
def test_non_wav_input_is_rejected(data: bytes) -> None:
    assert reason_for(data) == "not_wav"


def test_missing_fmt_chunk_is_rejected() -> None:
    data = b"RIFF" + struct.pack("<I", 12) + b"WAVE" + b"data" + struct.pack("<I", 0)

    assert reason_for(data) == "not_wav"


def test_header_cut_short_is_rejected() -> None:
    assert reason_for(make_wav()[:30]) == "not_wav"


def test_data_cut_short_is_truncated() -> None:
    wav_bytes = make_wav(16_000)

    assert reason_for(wav_bytes[:-100]) == "truncated"


# --- size and type --------------------------------------------------------------------


def test_input_over_1_mib_is_rejected_before_parsing(monkeypatch: pytest.MonkeyPatch) -> None:
    opened: list[object] = []
    monkeypatch.setattr(audio_module.wave, "open", lambda *args: opened.append(args))

    assert reason_for(b"\x00" * (MAX_WAV_BYTES + 1)) == "too_large"
    assert opened == []


def test_exactly_1_mib_is_parsed() -> None:
    assert MAX_WAV_BYTES == 1024 * 1024
    # Parsed (and rejected as not WAV), not refused for size.
    assert reason_for(b"\x00" * MAX_WAV_BYTES) == "not_wav"


@pytest.mark.parametrize("data", ["RIFF....WAVE", None, [1, 2, 3], 42, io.BytesIO(b"")])
def test_non_bytes_input_is_rejected(data: object) -> None:
    assert reason_for(data) == "invalid_type"


def test_errors_never_contain_audio_bytes() -> None:
    marker = b"SECRETAUDIO"
    for data in (marker * 10, make_wav(100, fill=b"SE"), make_wav(8_000, channels=2)):
        with pytest.raises(SpeechInvalidAudioError) as exc_info:
            parse_wav(data)
        error = exc_info.value
        for text in (str(error), repr(error)):
            assert "SECRET" not in text
            assert "SE" * 4 not in text
        assert error.__cause__ is None
