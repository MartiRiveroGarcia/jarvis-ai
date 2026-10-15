"""VoiceAssistantService: orchestration with a fake Speech client and fake model."""

import ast
import logging
import uuid
from pathlib import Path

import pytest

from app.integrations.foundry import FoundryTimeoutError
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
from app.models.user import User
from app.services import voice_assistant_service as voice_module
from app.services.assistant_errors import AssistantTimeoutError
from app.services.assistant_service import JARVIS_INSTRUCTIONS, AssistantService
from app.services.voice_assistant_service import VoiceAssistantService

WAV = b"RIFF-secret-recording-bytes"
TRANSCRIPT = "private spoken question"
REPLY = "private spoken answer"
MP3 = b"\xff\xf3secret-mp3-bytes"


class FakeSpeech:
    def __init__(self, events: list[tuple[str, object]], **errors: Exception) -> None:
        self.events = events
        self.errors = errors

    def transcribe(self, wav: bytes) -> str:
        self.events.append(("transcribe", wav))
        if error := self.errors.get("transcribe"):
            raise error
        return TRANSCRIPT

    def synthesize(self, text: str) -> bytes:
        self.events.append(("synthesize", text))
        if error := self.errors.get("synthesize"):
            raise error
        return MP3


class FakeGenerator:
    def __init__(self, events: list[tuple[str, object]], error: Exception | None = None) -> None:
        self.events = events
        self.error = error

    def generate(self, *, instructions: str, user_input: str) -> str:
        assert instructions == JARVIS_INSTRUCTIONS
        self.events.append(("assistant", user_input))
        if self.error is not None:
            raise self.error
        return REPLY


def make_service(
    *, speech_errors: dict[str, Exception] | None = None, model_error: Exception | None = None
) -> tuple[VoiceAssistantService, list[tuple[str, object]], list[FakeSpeech]]:
    events: list[tuple[str, object]] = []
    provided: list[FakeSpeech] = []

    def provider() -> FakeSpeech:
        provided.append(FakeSpeech(events, **(speech_errors or {})))
        return provided[-1]

    generator = FakeGenerator(events, model_error)
    assistant = AssistantService(generator_provider=lambda: generator)
    return (
        VoiceAssistantService(speech_provider=provider, assistant_service=assistant),
        events,
        provided,
    )


def a_user() -> User:
    return User(id=uuid.uuid4(), email="private-user@example.com", password_hash="x")


# --- orchestration --------------------------------------------------------------------


def test_stt_then_assistant_then_tts_with_exact_values() -> None:
    service, events, _ = make_service()

    mp3 = service.respond(a_user(), WAV)

    assert mp3 == MP3
    assert events == [
        ("transcribe", WAV),  # the recording, unchanged
        ("assistant", TRANSCRIPT),  # exactly the transcript
        ("synthesize", REPLY),  # exactly the reply
    ]


def test_one_speech_client_serves_stt_and_tts_in_a_request() -> None:
    service, _, provided = make_service()

    service.respond(a_user(), WAV)

    assert len(provided) == 1


def test_the_speech_client_is_requested_per_call_not_at_construction() -> None:
    service, _, provided = make_service()
    assert provided == []

    service.respond(a_user(), WAV)
    service.respond(a_user(), WAV)

    assert len(provided) == 2


# --- errors propagate unchanged ---------------------------------------------------------

SPEECH_ERRORS = [
    SpeechInvalidAudioError(reason="not_wav"),
    SpeechInvalidAudioError(reason="too_short"),
    SpeechNoSpeechError(session_id="abc"),
    SpeechTimeoutError(reason="timeout"),
    SpeechTimeoutError(reason="service_timeout", code="ServiceTimeout"),
    SpeechRateLimitedError(reason="too_many_requests", code="TooManyRequests"),
    SpeechUnavailableError(reason="unauthorized", code="AuthenticationFailure"),
    SpeechUnavailableError(reason="sdk_error"),
    SpeechBadResponseError(reason="unexpected_result"),
]


@pytest.mark.parametrize("error", SPEECH_ERRORS, ids=lambda e: f"{type(e).__name__}-{e.reason}")
def test_stt_errors_propagate_unchanged_and_stop_the_pipeline(error: SpeechError) -> None:
    service, events, _ = make_service(speech_errors={"transcribe": error})

    with pytest.raises(SpeechError) as exc_info:
        service.respond(a_user(), WAV)

    assert exc_info.value is error
    assert [name for name, _ in events] == ["transcribe"]


@pytest.mark.parametrize(
    "error",
    [
        SpeechTimeoutError(reason="timeout"),
        SpeechRateLimitedError(reason="too_many_requests"),
        SpeechUnavailableError(reason="forbidden", code="Forbidden"),
        SpeechBadResponseError(reason="empty_audio"),
        SpeechInvalidTextError(reason="too_long"),
    ],
    ids=lambda e: f"{type(e).__name__}-{e.reason}",
)
def test_tts_errors_propagate_unchanged(error: SpeechError) -> None:
    service, events, _ = make_service(speech_errors={"synthesize": error})

    with pytest.raises(SpeechError) as exc_info:
        service.respond(a_user(), WAV)

    assert exc_info.value is error
    assert [name for name, _ in events] == ["transcribe", "assistant", "synthesize"]


def test_assistant_errors_propagate_unchanged_and_skip_tts() -> None:
    service, events, _ = make_service(model_error=FoundryTimeoutError(reason="timeout"))

    with pytest.raises(AssistantTimeoutError):
        service.respond(a_user(), WAV)

    assert [name for name, _ in events] == ["transcribe", "assistant"]


def test_speech_not_configured_propagates_before_anything_runs() -> None:
    events: list[tuple[str, object]] = []

    def not_configured() -> FakeSpeech:
        raise SpeechNotConfiguredError

    service = VoiceAssistantService(
        speech_provider=not_configured,
        assistant_service=AssistantService(generator_provider=lambda: FakeGenerator(events)),
    )

    with pytest.raises(SpeechNotConfiguredError):
        service.respond(a_user(), WAV)

    assert events == []


def test_no_new_domain_errors_duplicate_speech_errors() -> None:
    from app.services import voice_errors

    names = {name for name in vars(voice_errors) if name.endswith("Error")}

    assert names == {"VoiceError", "VoiceUnsupportedMediaError", "VoiceTooLargeError"}


# --- logging ------------------------------------------------------------------------------


def voice_records(caplog: pytest.LogCaptureFixture) -> list[logging.LogRecord]:
    return [record for record in caplog.records if record.name == "jarvis.voice"]


def test_success_is_not_logged(caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.DEBUG)
    service, _, _ = make_service()

    service.respond(a_user(), WAV)

    assert voice_records(caplog) == []


@pytest.mark.parametrize(
    ("errors", "line", "level"),
    [
        (
            {"transcribe": SpeechNoSpeechError(session_id="abc")},
            "stage=stt error=SpeechNoSpeechError reason=no_speech code=None",
            logging.INFO,
        ),
        (
            {"transcribe": SpeechInvalidAudioError(reason="too_short")},
            "stage=stt error=SpeechInvalidAudioError reason=too_short code=None",
            logging.INFO,
        ),
        (
            {"transcribe": SpeechUnavailableError(reason="forbidden", code="Forbidden")},
            "stage=stt error=SpeechUnavailableError reason=forbidden code=Forbidden",
            logging.WARNING,
        ),
        (
            {"synthesize": SpeechTimeoutError(reason="timeout")},
            "stage=tts error=SpeechTimeoutError reason=timeout code=None",
            logging.WARNING,
        ),
    ],
)
def test_failures_log_one_line_of_fixed_metadata(
    caplog: pytest.LogCaptureFixture, errors: dict[str, Exception], line: str, level: int
) -> None:
    caplog.set_level(logging.DEBUG)
    service, _, _ = make_service(speech_errors=errors)

    with pytest.raises(SpeechError):
        service.respond(a_user(), WAV)

    [record] = voice_records(caplog)
    assert record.getMessage() == f"voice request failed: {line}"
    assert record.levelno == level
    assert record.exc_info is None


def test_not_configured_is_logged_at_info_as_stt_stage(caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.DEBUG)

    def not_configured() -> FakeSpeech:
        raise SpeechNotConfiguredError

    service = VoiceAssistantService(
        speech_provider=not_configured,
        assistant_service=AssistantService(generator_provider=lambda: FakeGenerator([])),
    )
    with pytest.raises(SpeechNotConfiguredError):
        service.respond(a_user(), WAV)

    [record] = voice_records(caplog)
    assert record.levelno == logging.INFO
    assert "stage=stt error=SpeechNotConfiguredError reason=not_configured" in record.getMessage()


def test_logs_never_contain_content_or_sizes(caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.DEBUG)
    for errors in (
        {"transcribe": SpeechTimeoutError(reason="timeout")},
        {"synthesize": SpeechUnavailableError(reason="connection")},
    ):
        service, _, _ = make_service(speech_errors=errors)
        with pytest.raises(SpeechError):
            service.respond(a_user(), WAV)
    service, _, _ = make_service(model_error=FoundryTimeoutError(reason="timeout"))
    with pytest.raises(AssistantTimeoutError):
        service.respond(a_user(), WAV)

    # No content from any logger.
    everything = caplog.text + repr([vars(record) for record in caplog.records])
    for secret in ("secret-recording", TRANSCRIPT, REPLY, "secret-mp3", "private-user"):
        assert secret not in everything
    # The assistant's own failure line (also emitted on the voice path) has no length.
    assistant = [r.getMessage() for r in caplog.records if r.name == "jarvis.assistant"]
    assert assistant == [
        "assistant request failed: error=FoundryTimeoutError reason=timeout "
        "status_code=None request_id=None"
    ]
    assert "input_length" not in everything
    assert str(len(TRANSCRIPT)) not in " ".join(assistant)
    # No sizes or durations from the voice logger.
    voice = " ".join(record.getMessage() for record in voice_records(caplog))
    assert voice
    for size in (len(WAV), len(MP3), len(TRANSCRIPT), len(REPLY)):
        assert str(size) not in voice
    for word in ("bytes", "length", "duration", "size"):
        assert word not in voice


# --- statelessness -------------------------------------------------------------------------


def test_service_module_uses_no_database_or_sdk() -> None:
    tree = ast.parse(Path(voice_module.__file__).read_text())
    imported = {
        node.module for node in ast.walk(tree) if isinstance(node, ast.ImportFrom) and node.module
    } | {
        alias.name
        for node in ast.walk(tree)
        if isinstance(node, ast.Import)
        for alias in node.names
    }

    forbidden = (
        "app.database",
        "app.repositories",
        "sqlalchemy",
        "azure",
        "openai",
        "app.integrations.speech._sdk",
    )
    assert not [name for name in imported if name.startswith(forbidden)]


def test_the_language_policy_is_not_duplicated_in_the_voice_path() -> None:
    # Voice reaches the model only through AssistantService and its shared instruction.
    root = Path(__file__).resolve().parents[1] / "app"
    for path in (
        root / "services" / "voice_assistant_service.py",
        root / "controllers" / "voice_controller.py",
    ):
        source = path.read_text()
        assert "Catalan" not in source, path.name
        assert "instructions" not in source, path.name
