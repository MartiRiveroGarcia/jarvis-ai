"""POST /api/assistant/respond: auth, validation, error mapping and lazy Foundry wiring.

Most tests replace the assistant service with one built on a fake generator. The
"real wiring" tests use the real dependencies and client with the real openai SDK
over an in-process mock transport and stand-in Azure credentials: no Azure access.
"""

import json
import logging
from collections.abc import Callable, Iterator
from typing import Any

import httpx2
import openai
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.config.settings import Settings, get_settings
from app.controllers.error_handlers import ASSISTANT_ERROR_STATUS
from app.database.base import Base
from app.database.session import get_engine, get_session_factory
from app.database.types import utc_now
from app.dependencies import get_assistant_service, get_foundry_client
from app.integrations.foundry import (
    FoundryBadResponseError,
    FoundryError,
    FoundryNotConfiguredError,
    FoundryRateLimitedError,
    FoundryRejectedError,
    FoundryResponsesClient,
    FoundryTimeoutError,
    FoundryUnavailableError,
)
from app.integrations.foundry import responses_client as responses_module
from app.main import create_app
from app.models import User
from app.repositories.auth_session_repository import AuthSessionRepository
from app.schemas.assistant import MAX_MESSAGE_LENGTH
from app.security.session_tokens import generate_session_token, hash_session_token
from app.services import assistant_errors
from app.services.assistant_service import JARVIS_INSTRUCTIONS, AssistantService

PATH = "/api/assistant/respond"
EMAIL = "marti@example.com"
PASSWORD = "correct horse battery staple"
MESSAGE = "What is retrieval augmented generation?"
REPLY = "A way to ground answers in your own documents."
GENERIC_401 = {"detail": "Invalid or expired session"}

ENDPOINT = "https://res-secret.services.ai.azure.com/api/projects/proj"
DEPLOYMENT = "deployment-secret"
UPSTREAM_SECRET = "upstream-detail-secret"


class FakeGenerator:
    def __init__(self, reply: str = REPLY, error: Exception | None = None) -> None:
        self.reply = reply
        self.error = error
        self.calls: list[str] = []

    def generate(self, *, instructions: str, user_input: str) -> str:
        assert instructions == JARVIS_INSTRUCTIONS
        self.calls.append(user_input)
        if self.error is not None:
            raise self.error
        return self.reply


# --- fixtures --------------------------------------------------------------------


@pytest.fixture
def make_client(database_url: str) -> Iterator[Callable[..., TestClient]]:
    Base.metadata.create_all(get_engine())
    clients: list[TestClient] = []

    def factory(generator: FakeGenerator | None = None) -> TestClient:
        app = create_app()
        settings = Settings(_env_file=None, environment="test")
        app.dependency_overrides[get_settings] = lambda: settings
        if generator is not None:
            app.dependency_overrides[get_assistant_service] = lambda: AssistantService(
                generator_provider=lambda: generator
            )
        client = TestClient(app)
        clients.append(client)
        return client

    yield factory
    for client in clients:
        client.close()


@pytest.fixture
def generator() -> FakeGenerator:
    return FakeGenerator()


@pytest.fixture
def api(make_client: Callable[..., TestClient], generator: FakeGenerator) -> TestClient:
    return make_client(generator)


@pytest.fixture
def db() -> Iterator[Session]:
    with get_session_factory()() as session:
        yield session


def _token(api: TestClient) -> str:
    api.post("/api/auth/register", json={"email": EMAIL, "password": PASSWORD})
    return api.post("/api/auth/login", json={"email": EMAIL, "password": PASSWORD}).json()[
        "session_token"
    ]


def _bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _ask(api: TestClient, payload: Any = None, token: str | None = None) -> httpx2.Response:
    token = token if token is not None else _token(api)
    return api.post(
        PATH, json={"message": MESSAGE} if payload is None else payload, headers=_bearer(token)
    )


def _failing_api(make_client: Callable[..., TestClient], error: FoundryError) -> TestClient:
    return make_client(FakeGenerator(error=error))


# --- success ---------------------------------------------------------------------


def test_authenticated_message_returns_the_reply(api: TestClient, generator: FakeGenerator) -> None:
    response = _ask(api)

    assert response.status_code == 200
    assert response.json() == {"reply": REPLY}
    assert generator.calls == [MESSAGE]


def test_message_is_trimmed_before_it_is_sent(api: TestClient, generator: FakeGenerator) -> None:
    response = _ask(api, {"message": "  \n hello Jarvis \t "})

    assert response.status_code == 200
    assert generator.calls == ["hello Jarvis"]


def test_maximum_length_message_is_accepted(api: TestClient, generator: FakeGenerator) -> None:
    message = "x" * MAX_MESSAGE_LENGTH

    assert _ask(api, {"message": f"  {message}  "}).status_code == 200
    assert generator.calls == [message]


def test_nothing_is_persisted(api: TestClient, db: Session) -> None:
    token = _token(api)
    tables_before = set(db.execute(text("SELECT name FROM sqlite_master")).scalars())

    assert _ask(api, token=token).status_code == 200

    everything = repr(db.execute(text("SELECT * FROM users")).all()) + repr(
        db.execute(text("SELECT * FROM auth_sessions")).all()
    )
    assert MESSAGE not in everything
    assert REPLY not in everything
    assert set(db.execute(text("SELECT name FROM sqlite_master")).scalars()) == tables_before


# --- authentication --------------------------------------------------------------


def _expired_token(db: Session) -> str:
    user = User(email="expired@example.com", password_hash="$argon2id$placeholder")
    db.add(user)
    db.flush()
    token = generate_session_token()
    AuthSessionRepository(db).create(user.id, hash_session_token(token), utc_now())
    db.commit()
    return token


def test_every_auth_failure_is_the_generic_401(
    api: TestClient, db: Session, generator: FakeGenerator
) -> None:
    failures = {
        "missing header": {},
        "basic scheme": {"Authorization": "Basic dXNlcjpwYXNz"},
        "malformed token": _bearer("not-a-token"),
        "unknown token": _bearer(generate_session_token()),
        "expired token": _bearer(_expired_token(db)),
    }

    for name, headers in failures.items():
        response = api.post(PATH, json={"message": MESSAGE}, headers=headers)
        assert response.status_code == 401, name
        assert response.json() == GENERIC_401, name
        assert response.headers["www-authenticate"] == "Bearer", name
    assert generator.calls == []


def test_revoked_session_is_rejected(api: TestClient) -> None:
    token = _token(api)
    api.post("/api/auth/logout", headers=_bearer(token))

    assert _ask(api, token=token).status_code == 401


@pytest.mark.parametrize("payload", [{}, {"message": ""}, {"message": "x" * 5000}, {"x": 1}])
def test_unauthenticated_invalid_body_gets_401_not_422(api: TestClient, payload: Any) -> None:
    response = api.post(PATH, json=payload)

    assert response.status_code == 401
    assert response.json() == GENERIC_401


# --- validation ------------------------------------------------------------------


@pytest.mark.parametrize(
    "payload",
    [
        {},
        {"message": ""},
        {"message": "   \n\t  "},
        {"message": "x" * (MAX_MESSAGE_LENGTH + 1)},
        {"message": None},
        {"message": 42},
        {"message": MESSAGE, "previous_response_id": "resp_1"},
        {"message": MESSAGE, "history": []},
        [MESSAGE],
    ],
)
def test_invalid_bodies_return_422(api: TestClient, generator: FakeGenerator, payload: Any) -> None:
    response = _ask(api, payload)

    assert response.status_code == 422
    assert isinstance(response.json()["detail"], list)
    assert generator.calls == []


def test_validation_errors_never_echo_the_message(api: TestClient) -> None:
    secret = "my-secret-diary-entry " * 200  # over the limit

    response = _ask(api, {"message": secret, "leak": "leak-me-too"})

    assert response.status_code == 422
    assert "my-secret-diary-entry" not in response.text
    assert "leak-me-too" not in response.text


def test_whitespace_padding_does_not_count_towards_the_limit(api: TestClient) -> None:
    message = " " * 100 + "x" * MAX_MESSAGE_LENGTH + " " * 100

    assert _ask(api, {"message": message}).status_code == 200


# --- error mapping ---------------------------------------------------------------


@pytest.mark.parametrize(
    ("error", "status", "detail"),
    [
        (FoundryNotConfiguredError(), 503, "The assistant is not available"),
        (
            FoundryUnavailableError(reason="forbidden", status_code=403),
            503,
            "The assistant is temporarily unavailable",
        ),
        (
            FoundryUnavailableError(reason="connection"),
            503,
            "The assistant is temporarily unavailable",
        ),
        (
            FoundryBadResponseError(reason="malformed"),
            503,
            "The assistant is temporarily unavailable",
        ),
        (FoundryTimeoutError(reason="timeout"), 504, "The assistant took too long to respond"),
        (
            FoundryRateLimitedError(status_code=429),
            429,
            "The assistant is busy. Please try again shortly",
        ),
        (
            FoundryRejectedError(reason="content_filter", status_code=400),
            422,
            "The assistant couldn't answer that request",
        ),
    ],
)
def test_assistant_failures_map_to_safe_responses(
    make_client: Callable[..., TestClient], error: FoundryError, status: int, detail: str
) -> None:
    api = _failing_api(make_client, error)

    response = _ask(api)

    assert response.status_code == status
    assert response.json() == {"detail": detail}
    assert "retry-after" not in response.headers
    assert response.headers["cache-control"] == "no-store"


@pytest.mark.parametrize(
    ("retry_after", "header"), [(1.0, "1"), (2.4, "3"), (120.0, "120"), (3600.0, "120"), (0.0, "0")]
)
def test_rate_limit_forwards_a_capped_retry_after(
    make_client: Callable[..., TestClient], retry_after: float, header: str
) -> None:
    api = _failing_api(
        make_client, FoundryRateLimitedError(status_code=429, retry_after=retry_after)
    )

    response = _ask(api)

    assert response.status_code == 429
    assert response.headers["retry-after"] == header


def test_rate_limit_without_a_usable_hint_sends_no_retry_after(
    make_client: Callable[..., TestClient],
) -> None:
    api = _failing_api(make_client, FoundryRateLimitedError(status_code=429, retry_after=None))

    response = _ask(api)

    assert response.status_code == 429
    assert "retry-after" not in response.headers


def test_every_assistant_error_has_an_http_mapping() -> None:
    domain_errors = {
        obj
        for obj in vars(assistant_errors).values()
        if isinstance(obj, type)
        and issubclass(obj, assistant_errors.AssistantError)
        and obj is not assistant_errors.AssistantError
    }

    assert domain_errors == set(ASSISTANT_ERROR_STATUS)


def test_error_responses_contain_no_upstream_details(
    make_client: Callable[..., TestClient],
) -> None:
    error = FoundryUnavailableError(reason="forbidden", status_code=403, request_id="req-secret")
    error.args = (UPSTREAM_SECRET, ENDPOINT, DEPLOYMENT)
    api = _failing_api(make_client, error)

    response = _ask(api)

    raw = response.text + repr(dict(response.headers))
    for secret in (
        UPSTREAM_SECRET,
        ENDPOINT,
        DEPLOYMENT,
        "req-secret",
        "403",
        "forbidden",
        MESSAGE,
    ):
        assert secret not in raw


def test_rejected_body_differs_from_a_validation_error(
    make_client: Callable[..., TestClient],
) -> None:
    api = _failing_api(make_client, FoundryRejectedError(reason="refusal"))

    assert isinstance(_ask(api).json()["detail"], str)
    assert isinstance(_ask(api, {"message": ""}).json()["detail"], list)


# --- caching headers -------------------------------------------------------------


def test_assistant_responses_are_not_cacheable(api: TestClient) -> None:
    token = _token(api)
    responses = [
        _ask(api, token=token),  # 200
        _ask(api, {"message": ""}, token=token),  # 422
        api.post(PATH, json={"message": MESSAGE}),  # 401
    ]

    for response in responses:
        assert response.headers["cache-control"] == "no-store", response.status_code


def test_health_is_still_cacheable(api: TestClient) -> None:
    assert "cache-control" not in api.get("/api/health").headers


# --- OpenAPI ---------------------------------------------------------------------


def test_openapi_documents_the_endpoint(api: TestClient) -> None:
    schema = api.get("/openapi.json").json()

    operation = schema["paths"][PATH]["post"]
    assert operation["security"] == [{"HTTPBearer": []}]
    request_schema = schema["components"]["schemas"]["AssistantRequest"]
    assert request_schema["properties"]["message"]["maxLength"] == MAX_MESSAGE_LENGTH
    assert request_schema["properties"]["message"]["minLength"] == 1
    assert request_schema["additionalProperties"] is False
    assert schema["components"]["schemas"]["AssistantResponse"]["required"] == ["reply"]


# --- real wiring: not configured -------------------------------------------------


def test_without_foundry_only_the_assistant_is_unavailable(
    make_client: Callable[..., TestClient], caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.DEBUG, logger="jarvis.assistant")
    api = make_client()  # real dependencies; conftest guarantees no Foundry settings
    token = _token(api)

    assert get_settings().foundry_configured is False
    assert api.get("/api/health").status_code == 200
    assert api.get("/api/auth/me", headers=_bearer(token)).status_code == 200

    response = _ask(api, token=token)

    assert response.status_code == 503
    assert response.json() == {"detail": "The assistant is not available"}
    # Not configured is never cached: configuration is re-checked on each request.
    assert get_foundry_client.cache_info().currsize == 0
    [record] = [r for r in caplog.records if r.name == "jarvis.assistant"]
    assert record.levelname == "INFO"


# --- real wiring: configured, lazy client ----------------------------------------


def _completed(text_reply: str) -> dict[str, Any]:
    return {
        "id": "resp_1",
        "object": "response",
        "created_at": 1,
        "model": DEPLOYMENT,
        "status": "completed",
        "output": [
            {
                "id": "msg_1",
                "type": "message",
                "role": "assistant",
                "status": "completed",
                "content": [{"type": "output_text", "text": text_reply, "annotations": []}],
            }
        ],
        "parallel_tool_calls": False,
        "tool_choice": "auto",
        "tools": [],
    }


class FakeAzure:
    """Stand-ins for azure.identity plus an in-process Foundry over a mock transport."""

    def __init__(self) -> None:
        self.events: list[str] = []
        self.requests: list[httpx2.Request] = []

    def handle(self, request: httpx2.Request) -> httpx2.Response:
        self.requests.append(request)
        return httpx2.Response(200, json=_completed(REPLY))


@pytest.fixture
def fake_azure(monkeypatch: pytest.MonkeyPatch) -> FakeAzure:
    import azure.identity

    fake = FakeAzure()

    class FakeCredential:
        def __init__(self) -> None:
            fake.events.append("credential")

    def fake_provider_factory(_credential: object, scope: str) -> Callable[[], str]:
        fake.events.append(f"provider:{scope}")

        def token() -> str:
            fake.events.append("token")
            return "fake-entra-token"

        return token

    real_openai = openai.OpenAI

    def openai_over_mock_transport(**kwargs: Any) -> openai.OpenAI:
        fake.events.append("sdk_client")
        kwargs["http_client"] = httpx2.Client(transport=httpx2.MockTransport(fake.handle))
        return real_openai(**kwargs)

    monkeypatch.setattr(azure.identity, "DefaultAzureCredential", FakeCredential)
    monkeypatch.setattr(azure.identity, "get_bearer_token_provider", fake_provider_factory)
    monkeypatch.setattr(responses_module, "OpenAI", openai_over_mock_transport)
    for name in ("OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_ORG_ID", "OPENAI_PROJECT_ID"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("JARVIS_FOUNDRY_PROJECT_ENDPOINT", ENDPOINT)
    monkeypatch.setenv("JARVIS_FOUNDRY_MODEL", DEPLOYMENT)
    get_settings.cache_clear()
    return fake


def test_foundry_client_is_created_lazily_and_reused(
    make_client: Callable[..., TestClient], fake_azure: FakeAzure
) -> None:
    api = make_client()  # real dependencies
    token = _token(api)
    api.get("/api/health")
    api.get("/api/auth/me", headers=_bearer(token))

    # Startup, health and auth: no client, credential, token or HTTP call.
    assert get_foundry_client.cache_info().currsize == 0
    assert fake_azure.events == []
    assert fake_azure.requests == []

    first = _ask(api, token=token)
    second = _ask(api, {"message": "second"}, token=token)

    assert first.json() == second.json() == {"reply": REPLY}
    # One credential, provider and SDK client for the process; a token per request.
    assert fake_azure.events == [
        "credential",
        "provider:https://ai.azure.com/.default",
        "sdk_client",
        "token",
        "token",
    ]
    assert isinstance(get_foundry_client(), FoundryResponsesClient)
    assert get_foundry_client.cache_info().currsize == 1


def test_real_wiring_sends_one_stateless_request(
    make_client: Callable[..., TestClient], fake_azure: FakeAzure
) -> None:
    api = make_client()

    assert _ask(api, {"message": "  hello  "}).status_code == 200

    [request] = fake_azure.requests
    assert str(request.url) == ENDPOINT + "/openai/v1/responses"
    body = json.loads(request.content)
    assert body["model"] == DEPLOYMENT
    assert body["instructions"] == JARVIS_INSTRUCTIONS
    assert body["input"] == "hello"
    assert body["store"] is False
    for stateful in ("previous_response_id", "conversation", "tools", "stream"):
        assert stateful not in body
    # The Jarvis session token never goes upstream.
    assert request.headers["authorization"] == "Bearer fake-entra-token"
