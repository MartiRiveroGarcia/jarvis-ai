"""FoundryResponsesClient tests: the real openai SDK over a mock HTTP transport.

No Azure CLI, credentials or network: tokens come from a fake provider and every
HTTP exchange is handled in-process by httpx2.MockTransport.
"""

import json
from collections.abc import Callable, Iterator
from typing import Any

import httpx2
import pytest
from azure.core.exceptions import ClientAuthenticationError

from app.config.settings import Settings
from app.integrations.foundry import (
    FOUNDRY_TOKEN_SCOPE,
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

ENDPOINT = "https://res-secret.services.ai.azure.com/api/projects/proj"
DEPLOYMENT = "deployment-secret"
TOKEN = "fake-entra-token-secret"
INSTRUCTIONS = "You are a test assistant."
USER_INPUT = "my private question"
RESPONSES_URL = ENDPOINT + "/openai/v1/responses"

Handler = Callable[[httpx2.Request], httpx2.Response]


@pytest.fixture(autouse=True)
def no_openai_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    # The SDK reads OPENAI_* variables (organization, project, base URL) from the env.
    for name in ("OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_ORG_ID", "OPENAI_PROJECT_ID"):
        monkeypatch.delenv(name, raising=False)


class Recorder:
    """Records requests and token-provider calls."""

    def __init__(self, handler: Handler) -> None:
        self.handler = handler
        self.requests: list[httpx2.Request] = []
        self.token_calls = 0

    def transport(self, request: httpx2.Request) -> httpx2.Response:
        self.requests.append(request)
        return self.handler(request)

    def token(self) -> str:
        self.token_calls += 1
        return TOKEN

    @property
    def body(self) -> dict[str, Any]:
        return json.loads(self.requests[-1].content)


def completed(text: str = "Hello from Foundry.", **extra: Any) -> dict[str, Any]:
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
                "content": [{"type": "output_text", "text": text, "annotations": []}],
            }
        ],
        "parallel_tool_calls": False,
        "tool_choice": "auto",
        "tools": [],
        **extra,
    }


def respond(status: int = 200, body: Any = None, **headers: str) -> Handler:
    return lambda _request: httpx2.Response(
        status, json=completed() if body is None else body, headers=headers
    )


def make_client(
    recorder: Recorder, *, reasoning_effort: str | None = "low", timeout: float = 25
) -> FoundryResponsesClient:
    return FoundryResponsesClient(
        project_endpoint=ENDPOINT,
        deployment=DEPLOYMENT,
        timeout_seconds=timeout,
        max_output_tokens=2000,
        reasoning_effort=reasoning_effort,
        token_provider=recorder.token,
        http_client=httpx2.Client(transport=httpx2.MockTransport(recorder.transport)),
    )


def generate(client: FoundryResponsesClient) -> str:
    return client.generate(instructions=INSTRUCTIONS, user_input=USER_INPUT)


def fail(handler: Handler) -> tuple[FoundryError, Recorder]:
    recorder = Recorder(handler)
    with pytest.raises(FoundryError) as exc_info:
        generate(make_client(recorder))
    return exc_info.value, recorder


# --- request -----------------------------------------------------------------------


def test_request_targets_the_project_responses_endpoint() -> None:
    recorder = Recorder(respond())

    generate(make_client(recorder))

    request = recorder.requests[0]
    assert request.method == "POST"
    assert str(request.url) == RESPONSES_URL
    assert request.url.query == b""
    assert request.headers["authorization"] == f"Bearer {TOKEN}"


def test_request_body_is_one_stateless_call() -> None:
    recorder = Recorder(respond())

    generate(make_client(recorder))

    assert recorder.body == {
        "model": DEPLOYMENT,
        "instructions": INSTRUCTIONS,
        "input": USER_INPUT,
        "store": False,
        "max_output_tokens": 2000,
        "reasoning": {"effort": "low"},
    }


def test_reasoning_can_be_omitted() -> None:
    recorder = Recorder(respond())

    generate(make_client(recorder, reasoning_effort=None))

    assert "reasoning" not in recorder.body


def test_configured_timeout_is_applied_to_the_request() -> None:
    recorder = Recorder(respond())

    generate(make_client(recorder, timeout=7))

    timeouts = recorder.requests[0].extensions["timeout"]
    assert set(timeouts.values()) == {7}


def test_endpoint_trailing_slash_is_not_duplicated() -> None:
    recorder = Recorder(respond())
    client = FoundryResponsesClient(
        project_endpoint=ENDPOINT + "/",
        deployment=DEPLOYMENT,
        timeout_seconds=25,
        max_output_tokens=2000,
        token_provider=recorder.token,
        http_client=httpx2.Client(transport=httpx2.MockTransport(recorder.transport)),
    )

    generate(client)

    assert str(recorder.requests[0].url) == RESPONSES_URL


# --- lazy initialisation -------------------------------------------------------------


def test_constructing_the_client_does_no_auth_or_io() -> None:
    recorder = Recorder(respond())

    client = make_client(recorder)

    assert recorder.token_calls == 0
    assert recorder.requests == []
    assert "initialized=False" in repr(client)


def test_sdk_client_is_built_once_and_reused() -> None:
    recorder = Recorder(respond())
    client = make_client(recorder)

    generate(client)
    first = client._client
    generate(client)

    assert first is not None
    assert client._client is first
    assert len(recorder.requests) == 2


class FakeCredential:
    created = 0

    def __init__(self) -> None:
        FakeCredential.created += 1


@pytest.fixture
def fake_azure_identity(monkeypatch: pytest.MonkeyPatch) -> Iterator[list[str]]:
    import azure.identity

    scopes: list[str] = []
    FakeCredential.created = 0

    def fake_provider_factory(credential: object, scope: str) -> Callable[[], str]:
        assert isinstance(credential, FakeCredential)
        scopes.append(scope)
        return lambda: TOKEN

    monkeypatch.setattr(azure.identity, "DefaultAzureCredential", FakeCredential)
    monkeypatch.setattr(azure.identity, "get_bearer_token_provider", fake_provider_factory)
    yield scopes


def test_entra_credential_is_created_only_on_first_generate(
    fake_azure_identity: list[str],
) -> None:
    recorder = Recorder(respond())
    client = FoundryResponsesClient(
        project_endpoint=ENDPOINT,
        deployment=DEPLOYMENT,
        timeout_seconds=25,
        max_output_tokens=2000,
        http_client=httpx2.Client(transport=httpx2.MockTransport(recorder.transport)),
    )
    assert FakeCredential.created == 0

    generate(client)
    generate(client)

    assert FakeCredential.created == 1
    assert fake_azure_identity == [FOUNDRY_TOKEN_SCOPE] == ["https://ai.azure.com/.default"]
    assert recorder.requests[0].headers["authorization"] == f"Bearer {TOKEN}"


def test_credential_construction_failure_is_unavailable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import azure.identity

    def broken_credential() -> None:
        raise ClientAuthenticationError(f"cannot read {TOKEN} from environment")

    monkeypatch.setattr(azure.identity, "DefaultAzureCredential", broken_credential)
    client = FoundryResponsesClient(
        project_endpoint=ENDPOINT,
        deployment=DEPLOYMENT,
        timeout_seconds=25,
        max_output_tokens=2000,
    )

    with pytest.raises(FoundryUnavailableError) as exc_info:
        generate(client)

    assert exc_info.value.reason == "credential"
    assert TOKEN not in str(exc_info.value)


# --- settings ---------------------------------------------------------------------


def test_from_settings_without_configuration_raises_not_configured() -> None:
    with pytest.raises(FoundryNotConfiguredError) as exc_info:
        FoundryResponsesClient.from_settings(Settings(_env_file=None))

    assert exc_info.value.reason == "not_configured"
    assert not isinstance(exc_info.value, FoundryUnavailableError)


def test_from_settings_uses_the_configured_values() -> None:
    settings = Settings(
        _env_file=None,
        foundry_project_endpoint=ENDPOINT,
        foundry_model=DEPLOYMENT,
        foundry_timeout_seconds=30,
        foundry_max_output_tokens=1234,
    )

    client = FoundryResponsesClient.from_settings(settings)

    assert client._base_url == ENDPOINT + "/openai/v1"
    assert client._deployment == DEPLOYMENT
    assert client._timeout_seconds == 30
    assert client._max_output_tokens == 1234
    assert client._reasoning_effort == "low"
    assert DEPLOYMENT not in repr(client)
    assert "res-secret" not in repr(client)


# --- responses -------------------------------------------------------------------


def test_completed_response_returns_trimmed_text() -> None:
    recorder = Recorder(respond(body=completed("  Paris.  \n")))

    assert generate(make_client(recorder)) == "Paris."


def test_multiple_text_blocks_are_joined() -> None:
    body = completed()
    body["output"][0]["content"] = [
        {"type": "output_text", "text": "Hello ", "annotations": []},
        {"type": "output_text", "text": "world.", "annotations": []},
    ]
    recorder = Recorder(respond(body=body))

    assert generate(make_client(recorder)) == "Hello world."


def _reasoning_only() -> dict[str, Any]:
    body = completed()
    body["output"] = [{"id": "rs_1", "type": "reasoning", "summary": []}]
    return body


def _incomplete(reason: str) -> dict[str, Any]:
    return completed("partial", status="incomplete", incomplete_details={"reason": reason})


def _refusal_only() -> dict[str, Any]:
    body = completed()
    body["output"][0]["content"] = [{"type": "refusal", "refusal": "I can't help with that."}]
    return body


@pytest.mark.parametrize(
    ("body", "error_type", "reason"),
    [
        (completed(""), FoundryBadResponseError, "empty_output"),
        (completed("   \n"), FoundryBadResponseError, "empty_output"),
        (_reasoning_only(), FoundryBadResponseError, "empty_output"),
        (
            _incomplete("max_output_tokens"),
            FoundryBadResponseError,
            "incomplete_max_output_tokens",
        ),
        (_incomplete("content_filter"), FoundryRejectedError, "content_filter"),
        (completed("x", status="failed"), FoundryBadResponseError, "status_failed"),
        (_refusal_only(), FoundryRejectedError, "refusal"),
        ({"unexpected": True}, FoundryBadResponseError, "malformed"),
        (
            {"id": "r", "status": "completed", "output": "garbage"},
            FoundryBadResponseError,
            "malformed",
        ),
    ],
    ids=[
        "empty",
        "whitespace",
        "reasoning-only",
        "incomplete-max-output-tokens",
        "incomplete-content-filter",
        "failed",
        "refusal",
        "missing-fields",
        "garbage-output",
    ],
)
def test_unusable_responses(body: Any, error_type: type[FoundryError], reason: str) -> None:
    error, _ = fail(respond(body=body))

    assert type(error) is error_type
    assert error.reason == reason


@pytest.mark.parametrize(
    "response",
    [
        httpx2.Response(200, text="not json", headers={"content-type": "text/plain"}),
        httpx2.Response(200, text="{oops", headers={"content-type": "application/json"}),
    ],
    ids=["non-json", "invalid-json"],
)
def test_non_json_bodies_are_malformed(response: httpx2.Response) -> None:
    error, _ = fail(lambda _request: response)

    assert type(error) is FoundryBadResponseError
    assert error.reason == "malformed"


# --- status codes ------------------------------------------------------------------


def _error_body(code: str | None = None) -> dict[str, Any]:
    return {"error": {"message": f"upstream detail about {USER_INPUT}", "code": code}}


@pytest.mark.parametrize(
    ("status", "body", "error_type", "reason"),
    [
        (400, _error_body(), FoundryUnavailableError, "bad_request"),
        (400, _error_body("content_filter"), FoundryRejectedError, "content_filter"),
        (401, _error_body(), FoundryUnavailableError, "unauthorized"),
        (403, _error_body(), FoundryUnavailableError, "forbidden"),
        (404, _error_body(), FoundryUnavailableError, "not_found"),
        (422, _error_body(), FoundryUnavailableError, "bad_request"),
        (409, _error_body(), FoundryUnavailableError, "unexpected_status"),
        (429, _error_body(), FoundryRateLimitedError, "rate_limited"),
        (500, _error_body(), FoundryUnavailableError, "server_error"),
        (503, _error_body(), FoundryUnavailableError, "server_error"),
    ],
)
def test_status_codes_are_translated(
    status: int, body: dict[str, Any], error_type: type[FoundryError], reason: str
) -> None:
    error, recorder = fail(respond(status, body, **{"x-request-id": "req-123"}))

    assert type(error) is error_type
    assert error.reason == reason
    assert error.status_code == status
    assert error.request_id == "req-123"
    assert len(recorder.requests) == 1  # no SDK retries


def test_rate_limit_keeps_retry_after() -> None:
    error, _ = fail(respond(429, _error_body(), **{"retry-after": "7"}))

    assert isinstance(error, FoundryRateLimitedError)
    assert error.retry_after == 7


def test_rate_limit_ignores_invalid_retry_after() -> None:
    error, _ = fail(respond(429, _error_body(), **{"retry-after": "soon"}))

    assert isinstance(error, FoundryRateLimitedError)
    assert error.retry_after is None


# --- transport and credentials ---------------------------------------------------------


def _raise(exception: Exception) -> Handler:
    def handler(_request: httpx2.Request) -> httpx2.Response:
        raise exception

    return handler


def test_timeout_is_translated_and_not_retried() -> None:
    error, recorder = fail(_raise(httpx2.ReadTimeout("timed out")))

    assert type(error) is FoundryTimeoutError
    assert error.reason == "timeout"
    assert len(recorder.requests) == 1


def test_connection_failure_is_unavailable_and_not_retried() -> None:
    error, recorder = fail(_raise(httpx2.ConnectError(f"cannot connect to {ENDPOINT}")))

    assert type(error) is FoundryUnavailableError
    assert error.reason == "connection"
    assert len(recorder.requests) == 1


@pytest.mark.parametrize(
    "exception",
    [
        ClientAuthenticationError(f"Azure CLI not logged in; token {TOKEN}"),
        RuntimeError("unexpected credential failure"),
    ],
)
def test_token_provider_failure_is_unavailable_without_any_request(
    exception: Exception,
) -> None:
    recorder = Recorder(respond())

    def failing_provider() -> str:
        raise exception

    client = FoundryResponsesClient(
        project_endpoint=ENDPOINT,
        deployment=DEPLOYMENT,
        timeout_seconds=25,
        max_output_tokens=2000,
        token_provider=failing_provider,
        http_client=httpx2.Client(transport=httpx2.MockTransport(recorder.transport)),
    )

    with pytest.raises(FoundryUnavailableError) as exc_info:
        generate(client)

    assert exc_info.value.reason == "credential"
    assert recorder.requests == []


# --- privacy -------------------------------------------------------------------------

SECRETS = (TOKEN, "res-secret", DEPLOYMENT, USER_INPUT, "Hello from Foundry", "upstream detail")

FAILURES: list[Handler] = [
    respond(400, _error_body()),
    respond(400, _error_body("content_filter")),
    respond(401, _error_body()),
    respond(403, _error_body()),
    respond(404, _error_body()),
    respond(429, _error_body()),
    respond(500, _error_body()),
    respond(503, _error_body()),
    respond(body=_incomplete("max_output_tokens")),
    respond(body=completed("")),
    respond(body={"unexpected": True}),
    _raise(httpx2.ReadTimeout(f"timed out calling {ENDPOINT}")),
    _raise(httpx2.ConnectError(f"cannot connect to {ENDPOINT}")),
]


@pytest.mark.parametrize("handler", FAILURES)
def test_errors_never_expose_secrets_or_content(handler: Handler) -> None:
    error, _ = fail(handler)

    rendered = " ".join([str(error), repr(error), repr(error.args)])
    for secret in SECRETS:
        assert secret not in rendered
    # No SDK/Azure exception is attached: neither as cause nor as visible context.
    assert error.__cause__ is None
    assert error.__context__ is None or error.__suppress_context__ is True


def test_credential_errors_never_expose_azure_details() -> None:
    def failing_provider() -> str:
        raise ClientAuthenticationError(f"token {TOKEN} for {ENDPOINT}")

    client = FoundryResponsesClient(
        project_endpoint=ENDPOINT,
        deployment=DEPLOYMENT,
        timeout_seconds=25,
        max_output_tokens=2000,
        token_provider=failing_provider,
    )

    with pytest.raises(FoundryUnavailableError) as exc_info:
        generate(client)

    rendered = " ".join([str(exc_info.value), repr(exc_info.value)])
    assert TOKEN not in rendered
    assert "res-secret" not in rendered
    assert exc_info.value.__cause__ is None
    assert exc_info.value.__suppress_context__ is True


def test_module_has_no_api_key_fallback() -> None:
    # Entra ID only: nothing in the module reads an API key setting or variable.
    source = responses_module.__file__
    with open(source, encoding="utf-8") as module_file:
        text = module_file.read().lower()

    assert "api_key=" in text  # the SDK parameter, given the token provider
    assert "openai_api_key" not in text
    assert "foundry_api_key" not in text
    assert "azure_openai_api_key" not in text
