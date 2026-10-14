"""POST /api/voice/respond: auth-first ordering, raw WAV in / raw MP3 out, mappings.

Most tests replace the voice service with a recording fake. The wiring tests use the
real dependencies with fake Speech and model providers. Nothing contacts Azure.
"""

import logging
from collections.abc import Callable, Iterator
from typing import Any

import httpx2
import pytest
from fastapi.testclient import TestClient

from app import dependencies
from app.config.settings import Settings, get_settings
from app.controllers import voice_controller
from app.controllers.error_handlers import SPEECH_ERROR_RESPONSES, VOICE_ERROR_STATUS
from app.database.base import Base
from app.database.session import get_engine
from app.dependencies import get_voice_assistant_service
from app.integrations.foundry import FoundryRateLimitedError, FoundryTimeoutError
from app.integrations.speech import errors as speech_errors
from app.integrations.speech.audio import MAX_WAV_BYTES
from app.integrations.speech.errors import (
    SpeechBadResponseError,
    SpeechInvalidAudioError,
    SpeechInvalidTextError,
    SpeechNoSpeechError,
    SpeechNotConfiguredError,
    SpeechRateLimitedError,
    SpeechTimeoutError,
    SpeechUnavailableError,
)
from app.main import create_app
from app.models.user import User
from app.security.session_tokens import generate_session_token
from app.services.assistant_errors import (
    AssistantBusyError,
    AssistantNotConfiguredError,
    AssistantRequestRejectedError,
    AssistantTimeoutError,
    AssistantUnavailableError,
)
from app.services.assistant_service import JARVIS_INSTRUCTIONS

PATH = "/api/voice/respond"
EMAIL = "marti@example.com"
PASSWORD = "correct horse battery staple"
GENERIC_401 = {"detail": "Invalid or expired session"}
WAV = b"RIFF\x24\x00\x00\x00WAVEfmt secret-recording-bytes"
MP3 = b"\xff\xf3\x84\xc4secret-reply-audio" * 10
WAV_HEADERS = {"Content-Type": "audio/wav"}


class FakeVoiceService:
    def __init__(self, result: bytes = MP3, error: Exception | None = None) -> None:
        self.result = result
        self.error = error
        self.calls: list[tuple[User, bytes]] = []

    def respond(self, user: User, wav: bytes) -> bytes:
        self.calls.append((user, wav))
        if self.error is not None:
            raise self.error
        return self.result


@pytest.fixture
def make_client(database_url: str) -> Iterator[Callable[..., TestClient]]:
    Base.metadata.create_all(get_engine())
    clients: list[TestClient] = []

    def factory(service: FakeVoiceService | None = None) -> TestClient:
        app = create_app()
        settings = Settings(_env_file=None, environment="test")
        app.dependency_overrides[get_settings] = lambda: settings
        if service is not None:
            app.dependency_overrides[get_voice_assistant_service] = lambda: service
        client = TestClient(app, raise_server_exceptions=False)
        clients.append(client)
        return client

    yield factory
    for client in clients:
        client.close()


@pytest.fixture
def service() -> FakeVoiceService:
    return FakeVoiceService()


@pytest.fixture
def api(make_client: Callable[..., TestClient], service: FakeVoiceService) -> TestClient:
    return make_client(service)


@pytest.fixture
def body_reads(monkeypatch: pytest.MonkeyPatch) -> list[str]:
    """Record whether the controller ever started reading the request body."""
    reads: list[str] = []
    real_read = voice_controller._read_body

    async def recording_read(request: Any) -> bytes:
        reads.append("read")
        return await real_read(request)

    monkeypatch.setattr(voice_controller, "_read_body", recording_read)
    return reads


def _token(api: TestClient) -> str:
    api.post("/api/auth/register", json={"email": EMAIL, "password": PASSWORD})
    return api.post("/api/auth/login", json={"email": EMAIL, "password": PASSWORD}).json()[
        "session_token"
    ]


def _auth(token: str, **extra: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}", **extra}


def _send(
    api: TestClient, body: Any = WAV, headers: dict[str, str] | None = None
) -> httpx2.Response:
    token = _token(api)
    return api.post(PATH, content=body, headers=_auth(token, **(headers or WAV_HEADERS)))


# --- success ------------------------------------------------------------------------------


def test_raw_wav_in_exact_mp3_out(api: TestClient, service: FakeVoiceService) -> None:
    response = _send(api)

    assert response.status_code == 200
    assert response.content == MP3
    assert response.headers["content-type"] == "audio/mpeg"
    assert response.headers["content-length"] == str(len(MP3))
    assert response.headers["cache-control"] == "no-store"
    [(user, wav)] = service.calls
    assert wav == WAV  # unchanged
    assert user.email == EMAIL  # the authenticated caller


def test_media_type_parameters_and_case_are_tolerated(
    api: TestClient, service: FakeVoiceService
) -> None:
    for content_type in ("AUDIO/WAV", "audio/wav; codecs=1"):
        response = _send(api, headers={"Content-Type": content_type})
        assert response.status_code == 200, content_type


def test_exactly_1_mib_reaches_the_service(api: TestClient, service: FakeVoiceService) -> None:
    body = b"\x01" * MAX_WAV_BYTES

    assert _send(api, body).status_code == 200
    assert service.calls[0][1] == body


def test_an_empty_body_reaches_the_service_for_validation(
    make_client: Callable[..., TestClient],
) -> None:
    service = FakeVoiceService(error=SpeechInvalidAudioError(reason="not_wav"))
    api = make_client(service)

    response = _send(api, b"")

    assert response.status_code == 422
    assert service.calls[0][1] == b""


# --- authentication first -----------------------------------------------------------------


@pytest.mark.parametrize(
    "headers",
    [
        {},
        {"Authorization": "Basic dXNlcjpwYXNz"},
        {"Authorization": "Bearer not-a-token"},
    ],
)
def test_unauthenticated_requests_never_read_the_body(
    api: TestClient, service: FakeVoiceService, body_reads: list[str], headers: dict[str, str]
) -> None:
    response = api.post(PATH, content=WAV, headers={**WAV_HEADERS, **headers})

    assert response.status_code == 401
    assert response.json() == GENERIC_401
    assert response.headers["www-authenticate"] == "Bearer"
    assert response.headers["cache-control"] == "no-store"
    assert body_reads == []
    assert service.calls == []


def test_unknown_token_is_401(api: TestClient, service: FakeVoiceService) -> None:
    response = api.post(PATH, content=WAV, headers=_auth(generate_session_token(), **WAV_HEADERS))

    assert response.status_code == 401
    assert service.calls == []


def test_revoked_session_is_401(api: TestClient, service: FakeVoiceService) -> None:
    token = _token(api)
    api.post("/api/auth/logout", headers=_auth(token))

    response = api.post(PATH, content=WAV, headers=_auth(token, **WAV_HEADERS))

    assert response.status_code == 401
    assert service.calls == []


def test_unauthenticated_large_or_wrong_type_request_is_still_401(
    api: TestClient, service: FakeVoiceService, body_reads: list[str]
) -> None:
    for headers, body in (
        (WAV_HEADERS, b"\x00" * (MAX_WAV_BYTES + 1)),
        ({"Content-Type": "application/json"}, b"{}"),
    ):
        response = api.post(PATH, content=body, headers=headers)
        assert response.status_code == 401
    assert body_reads == []
    assert service.calls == []


# --- media type ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "content_type",
    [
        "audio/x-wav",
        "audio/wave",
        "audio/vnd.wave",
        "application/octet-stream",
        "multipart/form-data; boundary=xyz",
        "audio/mpeg",
        "application/json",
        "text/plain",
        "",
    ],
)
def test_only_audio_wav_is_accepted(
    api: TestClient, service: FakeVoiceService, body_reads: list[str], content_type: str
) -> None:
    response = _send(api, headers={"Content-Type": content_type})

    assert response.status_code == 415
    assert response.json() == {"detail": "The recording must be a WAV file"}
    assert response.headers["cache-control"] == "no-store"
    assert body_reads == []
    assert service.calls == []


def test_a_missing_content_type_is_415(
    api: TestClient, service: FakeVoiceService, body_reads: list[str]
) -> None:
    token = _token(api)

    response = api.post(PATH, content=WAV, headers=_auth(token))

    assert response.status_code == 415
    assert body_reads == []
    assert service.calls == []


# --- size limit ---------------------------------------------------------------------------


def test_declared_content_length_over_1_mib_is_413_before_reading(
    api: TestClient, service: FakeVoiceService, body_reads: list[str]
) -> None:
    response = _send(api, b"\x00" * (MAX_WAV_BYTES + 1))

    assert response.status_code == 413
    assert response.json() == {"detail": "The recording is too large"}
    assert response.headers["cache-control"] == "no-store"
    assert body_reads == []
    assert service.calls == []


def test_streamed_body_without_length_is_capped_while_reading(
    api: TestClient, service: FakeVoiceService, body_reads: list[str]
) -> None:
    def chunks() -> Iterator[bytes]:
        for _ in range(20):
            yield b"\x00" * 65_536  # 1.25 MiB in total, no Content-Length

    response = _send(api, chunks())

    assert response.status_code == 413
    assert body_reads == ["read"]
    assert service.calls == []


def test_streamed_body_within_the_limit_is_accepted(
    api: TestClient, service: FakeVoiceService
) -> None:
    def chunks() -> Iterator[bytes]:
        yield WAV[:10]
        yield WAV[10:]

    response = _send(api, chunks())

    assert response.status_code == 200
    assert service.calls[0][1] == WAV


# --- error mapping ------------------------------------------------------------------------

BUSY = "The assistant is busy. Please try again shortly"
SLOW = "The assistant took too long to respond"
UNAVAILABLE = "The assistant is temporarily unavailable"
NOT_AVAILABLE = "The assistant is not available"


@pytest.mark.parametrize(
    ("error", "status", "detail"),
    [
        (SpeechNotConfiguredError(), 503, NOT_AVAILABLE),
        (SpeechInvalidAudioError(reason="not_wav"), 422, "The recording could not be processed"),
        (SpeechInvalidAudioError(reason="too_short"), 422, "The recording could not be processed"),
        (SpeechInvalidAudioError(reason="too_long"), 422, "The recording could not be processed"),
        (SpeechNoSpeechError(session_id="abc"), 422, "Jarvis didn't hear anything"),
        (SpeechTimeoutError(reason="timeout"), 504, SLOW),
        (SpeechTimeoutError(reason="service_timeout", code="ServiceTimeout"), 504, SLOW),
        (SpeechRateLimitedError(reason="too_many_requests", code="TooManyRequests"), 429, BUSY),
        (
            SpeechUnavailableError(reason="unauthorized", code="AuthenticationFailure"),
            503,
            UNAVAILABLE,
        ),
        (SpeechUnavailableError(reason="credential"), 503, UNAVAILABLE),
        (SpeechBadResponseError(reason="empty_audio"), 503, UNAVAILABLE),
        (SpeechInvalidTextError(reason="too_long"), 503, UNAVAILABLE),
        (AssistantNotConfiguredError(), 503, NOT_AVAILABLE),
        (AssistantUnavailableError(), 503, UNAVAILABLE),
        (AssistantTimeoutError(), 504, SLOW),
        (AssistantBusyError(), 429, BUSY),
        (AssistantRequestRejectedError(), 422, "The assistant couldn't answer that request"),
    ],
    ids=lambda value: f"{type(value).__name__}" if isinstance(value, Exception) else str(value),
)
def test_failures_map_to_stable_content_free_responses(
    make_client: Callable[..., TestClient], error: Exception, status: int, detail: str
) -> None:
    api = make_client(FakeVoiceService(error=error))

    response = _send(api)

    assert response.status_code == status
    assert response.json() == {"detail": detail}
    assert response.headers["cache-control"] == "no-store"
    assert "retry-after" not in response.headers
    assert response.headers["content-type"] == "application/json"


def test_assistant_busy_keeps_its_retry_after(make_client: Callable[..., TestClient]) -> None:
    api = make_client(FakeVoiceService(error=AssistantBusyError(retry_after_seconds=7)))

    response = _send(api)

    assert response.status_code == 429
    assert response.headers["retry-after"] == "7"


def test_every_speech_and_voice_error_has_an_http_mapping() -> None:
    from app.services import voice_errors

    speech_types = {
        obj
        for obj in vars(speech_errors).values()
        if isinstance(obj, type)
        and issubclass(obj, speech_errors.SpeechError)
        and obj is not speech_errors.SpeechError
    }
    voice_types = {
        obj
        for obj in vars(voice_errors).values()
        if isinstance(obj, type)
        and issubclass(obj, voice_errors.VoiceError)
        and obj is not voice_errors.VoiceError
    }

    assert speech_types == set(SPEECH_ERROR_RESPONSES)
    assert voice_types == set(VOICE_ERROR_STATUS)


def test_error_responses_never_expose_details(make_client: Callable[..., TestClient]) -> None:
    error = SpeechUnavailableError(reason="forbidden", code="Forbidden", session_id="sess-secret")
    api = make_client(FakeVoiceService(error=error))

    response = _send(api)

    raw = response.text + repr(dict(response.headers))
    for secret in (
        "forbidden",
        "Forbidden",
        "sess-secret",
        "secret-recording",
        "SpeechUnavailable",
    ):
        assert secret not in raw


def test_an_unexpected_failure_is_a_bare_500(make_client: Callable[..., TestClient]) -> None:
    api = make_client(FakeVoiceService(error=RuntimeError("secret internal detail")))

    response = _send(api)

    assert response.status_code == 500
    assert response.text == "Internal Server Error"  # fixed and content-free
    # Unhandled exceptions are answered by Starlette's outer error middleware, so this
    # bare 500 (like on every other route) does not pass through the no-store middleware.


# --- real wiring --------------------------------------------------------------------------


class FakeSpeech:
    def __init__(self) -> None:
        self.events: list[tuple[str, object]] = []

    def transcribe(self, wav: bytes) -> str:
        self.events.append(("transcribe", wav))
        return "private question"

    def synthesize(self, text: str) -> bytes:
        self.events.append(("synthesize", text))
        return MP3


class FakeGenerator:
    def __init__(self, events: list[tuple[str, object]]) -> None:
        self.events = events

    def generate(self, *, instructions: str, user_input: str) -> str:
        assert instructions == JARVIS_INSTRUCTIONS
        self.events.append(("assistant", user_input))
        return "private answer"


def test_real_wiring_runs_stt_assistant_tts_with_one_speech_client(
    make_client: Callable[..., TestClient], monkeypatch: pytest.MonkeyPatch
) -> None:
    speech = FakeSpeech()
    provided: list[FakeSpeech] = []

    def speech_provider() -> FakeSpeech:
        provided.append(speech)
        return speech

    monkeypatch.setattr(dependencies, "get_speech_client", speech_provider)
    monkeypatch.setattr(dependencies, "get_foundry_client", lambda: FakeGenerator(speech.events))
    api = make_client()  # real dependencies

    response = _send(api)

    assert response.status_code == 200
    assert response.content == MP3
    assert speech.events == [
        ("transcribe", WAV),
        ("assistant", "private question"),
        ("synthesize", "private answer"),
    ]
    assert len(provided) == 1


def test_without_speech_only_the_voice_endpoint_is_unavailable(
    make_client: Callable[..., TestClient], caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.DEBUG)
    api = make_client()  # real dependencies; conftest guarantees no Azure settings
    token = _token(api)

    response = api.post(PATH, content=WAV, headers=_auth(token, **WAV_HEADERS))

    assert response.status_code == 503
    assert response.json() == {"detail": NOT_AVAILABLE}
    assert dependencies.get_speech_client.cache_info().currsize == 0  # never cached
    assert api.get("/api/health").status_code == 200
    assert api.get("/api/auth/me", headers=_auth(token)).status_code == 200
    [record] = [r for r in caplog.records if r.name == "jarvis.voice"]
    assert record.levelname == "INFO"
    assert "stage=stt error=SpeechNotConfiguredError" in record.getMessage()


def test_logs_from_a_failing_request_contain_no_content_or_sizes(
    make_client: Callable[..., TestClient],
    monkeypatch: pytest.MonkeyPatch,
    caplog: pytest.LogCaptureFixture,
) -> None:
    caplog.set_level(logging.DEBUG)

    class FailingSpeech(FakeSpeech):
        def synthesize(self, text: str) -> bytes:
            raise SpeechUnavailableError(reason="connection", code="ConnectionFailure")

    speech = FailingSpeech()
    monkeypatch.setattr(dependencies, "get_speech_client", lambda: speech)
    monkeypatch.setattr(dependencies, "get_foundry_client", lambda: FakeGenerator(speech.events))
    api = make_client()

    assert _send(api).status_code == 503

    logged = caplog.text
    for secret in ("secret-recording", "private question", "private answer", "secret-reply"):
        assert secret not in logged
    voice = [r.getMessage() for r in caplog.records if r.name == "jarvis.voice"]
    assert voice == [
        "voice request failed: stage=tts error=SpeechUnavailableError reason=connection "
        "code=ConnectionFailure"
    ]


def test_foundry_failures_keep_the_assistant_mapping_end_to_end(
    make_client: Callable[..., TestClient], monkeypatch: pytest.MonkeyPatch
) -> None:
    speech = FakeSpeech()

    class FailingGenerator(FakeGenerator):
        def generate(self, *, instructions: str, user_input: str) -> str:
            raise FoundryRateLimitedError(status_code=429, retry_after=2.5)

    monkeypatch.setattr(dependencies, "get_speech_client", lambda: speech)
    monkeypatch.setattr(dependencies, "get_foundry_client", lambda: FailingGenerator(speech.events))
    api = make_client()

    response = _send(api)

    assert response.status_code == 429
    assert response.headers["retry-after"] == "3"
    assert [name for name, _ in speech.events] == ["transcribe"]  # no synthesis


def test_foundry_timeout_end_to_end(
    make_client: Callable[..., TestClient], monkeypatch: pytest.MonkeyPatch
) -> None:
    speech = FakeSpeech()

    class SlowGenerator(FakeGenerator):
        def generate(self, *, instructions: str, user_input: str) -> str:
            raise FoundryTimeoutError(reason="timeout")

    monkeypatch.setattr(dependencies, "get_speech_client", lambda: speech)
    monkeypatch.setattr(dependencies, "get_foundry_client", lambda: SlowGenerator(speech.events))

    assert _send(make_client()).status_code == 504


# --- OpenAPI ------------------------------------------------------------------------------


def test_openapi_documents_raw_wav_in_and_mp3_out(api: TestClient) -> None:
    operation = api.get("/openapi.json").json()["paths"][PATH]["post"]

    assert operation["security"] == [{"HTTPBearer": []}]
    assert list(operation["requestBody"]["content"]) == ["audio/wav"]
    assert operation["requestBody"]["required"] is True
    assert "audio/mpeg" in operation["responses"]["200"]["content"]
