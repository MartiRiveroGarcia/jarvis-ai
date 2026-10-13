"""AssistantService tests with a fake generator: no SDK, no Azure, no database."""

import ast
import logging
import uuid
from pathlib import Path

import pytest

from app.integrations.foundry import (
    FoundryBadResponseError,
    FoundryError,
    FoundryNotConfiguredError,
    FoundryRateLimitedError,
    FoundryRejectedError,
    FoundryTimeoutError,
    FoundryUnavailableError,
)
from app.models.user import User
from app.services import assistant_errors
from app.services import assistant_service as assistant_module
from app.services.assistant_errors import (
    AssistantBusyError,
    AssistantError,
    AssistantNotConfiguredError,
    AssistantRequestRejectedError,
    AssistantTimeoutError,
    AssistantUnavailableError,
)
from app.services.assistant_service import (
    JARVIS_INSTRUCTIONS,
    MAX_RETRY_AFTER_SECONDS,
    AssistantService,
)

MESSAGE = "my private question about my calendar"
REPLY = "a private model reply"
SECRETS = (MESSAGE, REPLY, "fake-token-secret", "res-secret.services.ai", "deployment-secret")


class FakeGenerator:
    def __init__(self, reply: str = REPLY, error: Exception | None = None) -> None:
        self.reply = reply
        self.error = error
        self.calls: list[dict[str, str]] = []

    def generate(self, *, instructions: str, user_input: str) -> str:
        self.calls.append({"instructions": instructions, "user_input": user_input})
        if self.error is not None:
            raise self.error
        return self.reply


def service_for(generator: FakeGenerator) -> AssistantService:
    return AssistantService(generator_provider=lambda: generator)


def a_user() -> User:
    return User(id=uuid.uuid4(), email="private-user@example.com", password_hash="x")


def failure(error: FoundryError) -> AssistantError:
    with pytest.raises(AssistantError) as exc_info:
        service_for(FakeGenerator(error=error)).respond(a_user(), MESSAGE)
    return exc_info.value


# --- success -------------------------------------------------------------------------


def test_instruction_is_the_fixed_jarvis_instruction() -> None:
    assert JARVIS_INSTRUCTIONS == "You are Jarvis, a concise and helpful personal assistant."


def test_respond_makes_exactly_one_call_with_instruction_and_message() -> None:
    generator = FakeGenerator()

    reply = service_for(generator).respond(a_user(), MESSAGE)

    assert reply == REPLY
    assert generator.calls == [{"instructions": JARVIS_INSTRUCTIONS, "user_input": MESSAGE}]


def test_user_data_is_never_sent_to_the_generator() -> None:
    generator = FakeGenerator()

    service_for(generator).respond(a_user(), MESSAGE)

    assert "private-user@example.com" not in repr(generator.calls)


def test_requests_are_independent() -> None:
    # Stateless: the second call carries nothing from the first.
    generator = FakeGenerator()
    service = service_for(generator)

    service.respond(a_user(), "first message")
    service.respond(a_user(), "second message")

    assert generator.calls[1] == {
        "instructions": JARVIS_INSTRUCTIONS,
        "user_input": "second message",
    }


def test_generator_provider_is_called_per_request_not_at_construction() -> None:
    provided: list[FakeGenerator] = []

    def provider() -> FakeGenerator:
        provided.append(FakeGenerator())
        return provided[-1]

    service = AssistantService(generator_provider=provider)
    assert provided == []

    service.respond(a_user(), MESSAGE)
    assert len(provided) == 1


# --- error translation ---------------------------------------------------------------


def test_not_configured_provider_maps_to_not_configured() -> None:
    def not_configured() -> FakeGenerator:
        raise FoundryNotConfiguredError

    with pytest.raises(AssistantNotConfiguredError):
        AssistantService(generator_provider=not_configured).respond(a_user(), MESSAGE)


@pytest.mark.parametrize(
    ("error", "expected"),
    [
        (FoundryNotConfiguredError(), AssistantNotConfiguredError),
        (FoundryTimeoutError(reason="timeout"), AssistantTimeoutError),
        (FoundryRateLimitedError(status_code=429), AssistantBusyError),
        (
            FoundryRejectedError(reason="content_filter", status_code=400),
            AssistantRequestRejectedError,
        ),
        (FoundryRejectedError(reason="refusal"), AssistantRequestRejectedError),
        (FoundryUnavailableError(reason="connection"), AssistantUnavailableError),
        (FoundryUnavailableError(reason="credential"), AssistantUnavailableError),
        (FoundryUnavailableError(reason="forbidden", status_code=403), AssistantUnavailableError),
        (FoundryUnavailableError(reason="bad_request", status_code=400), AssistantUnavailableError),
        (
            FoundryUnavailableError(reason="server_error", status_code=500),
            AssistantUnavailableError,
        ),
        (FoundryBadResponseError(reason="malformed"), AssistantUnavailableError),
        (FoundryBadResponseError(reason="empty_output"), AssistantUnavailableError),
        (
            FoundryBadResponseError(reason="incomplete_max_output_tokens"),
            AssistantUnavailableError,
        ),
    ],
)
def test_foundry_errors_map_to_domain_errors(error: FoundryError, expected: type) -> None:
    domain_error = failure(error)

    assert type(domain_error) is expected
    # No chained Foundry error: nothing upstream can leak through tracebacks.
    assert domain_error.__cause__ is None
    assert domain_error.__suppress_context__ is True


def test_every_foundry_error_type_is_translated() -> None:
    foundry_errors = [
        FoundryNotConfiguredError(),
        FoundryTimeoutError(reason="r"),
        FoundryUnavailableError(reason="r"),
        FoundryRateLimitedError(),
        FoundryRejectedError(reason="r"),
        FoundryBadResponseError(reason="r"),
    ]
    assert {type(e) for e in foundry_errors} == set(FoundryError.__subclasses__())

    for error in foundry_errors:
        assert isinstance(failure(error), AssistantError)


def test_unexpected_non_foundry_errors_are_not_swallowed() -> None:
    with pytest.raises(RuntimeError):
        service_for(FakeGenerator(error=RuntimeError("bug"))).respond(a_user(), MESSAGE)


@pytest.mark.parametrize(
    ("retry_after", "expected"),
    [
        (None, None),
        (0.0, 0),
        (1.0, 1),
        (1.2, 2),
        (30.0, 30),
        (119.5, 120),
        (120.0, 120),
        (121.0, MAX_RETRY_AFTER_SECONDS),
        (86400.0, MAX_RETRY_AFTER_SECONDS),
        (float("inf"), MAX_RETRY_AFTER_SECONDS),
        (float("nan"), None),
        (-1.0, None),
    ],
)
def test_retry_after_is_rounded_up_and_capped(
    retry_after: float | None, expected: int | None
) -> None:
    error = failure(FoundryRateLimitedError(status_code=429, retry_after=retry_after))

    assert isinstance(error, AssistantBusyError)
    assert error.retry_after_seconds == expected


def test_domain_error_messages_are_fixed() -> None:
    assert str(AssistantNotConfiguredError()) == "The assistant is not available"
    assert str(AssistantUnavailableError()) == "The assistant is temporarily unavailable"
    assert str(AssistantTimeoutError()) == "The assistant took too long to respond"
    assert str(AssistantBusyError(5)) == "The assistant is busy. Please try again shortly"
    assert str(AssistantRequestRejectedError()) == "The assistant couldn't answer that request"


def test_domain_errors_carry_no_foundry_details() -> None:
    error = failure(FoundryUnavailableError(reason="forbidden", status_code=403, request_id="r-1"))

    assert vars(error) == {}
    assert str(error) == "The assistant is temporarily unavailable"


def test_every_domain_error_has_a_fixed_message() -> None:
    domain_errors = [
        obj
        for obj in vars(assistant_errors).values()
        if isinstance(obj, type) and issubclass(obj, AssistantError) and obj is not AssistantError
    ]

    assert len(domain_errors) == 5
    assert len({error.message for error in domain_errors}) == 5


# --- statelessness ---------------------------------------------------------------------


def test_service_module_uses_no_database_or_sdk() -> None:
    tree = ast.parse(Path(assistant_module.__file__).read_text())
    imported = {
        node.module for node in ast.walk(tree) if isinstance(node, ast.ImportFrom) and node.module
    } | {
        alias.name
        for node in ast.walk(tree)
        if isinstance(node, ast.Import)
        for alias in node.names
    }

    forbidden = ("app.database", "app.repositories", "sqlalchemy", "openai", "azure")
    assert not [name for name in imported if name.startswith(forbidden)]


# --- logging ---------------------------------------------------------------------------


def records(caplog: pytest.LogCaptureFixture) -> list[logging.LogRecord]:
    return [r for r in caplog.records if r.name == "jarvis.assistant"]


def test_success_is_not_logged(caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.DEBUG, logger="jarvis.assistant")

    service_for(FakeGenerator()).respond(a_user(), MESSAGE)

    assert records(caplog) == []


def test_upstream_failure_logs_one_warning_with_safe_fields(
    caplog: pytest.LogCaptureFixture,
) -> None:
    caplog.set_level(logging.DEBUG, logger="jarvis.assistant")

    failure(FoundryUnavailableError(reason="forbidden", status_code=403, request_id="req-123"))

    [record] = records(caplog)
    assert record.levelno == logging.WARNING
    assert record.getMessage() == (
        "assistant request failed: error=FoundryUnavailableError reason=forbidden "
        f"status_code=403 request_id=req-123 input_length={len(MESSAGE)}"
    )
    assert record.exc_info is None


@pytest.mark.parametrize(
    "error",
    [
        FoundryTimeoutError(reason="timeout"),
        FoundryRateLimitedError(status_code=429, retry_after=3),
        FoundryRejectedError(reason="content_filter", status_code=400),
        FoundryBadResponseError(reason="malformed"),
    ],
)
def test_runtime_failures_log_at_warning(
    caplog: pytest.LogCaptureFixture, error: FoundryError
) -> None:
    caplog.set_level(logging.DEBUG, logger="jarvis.assistant")

    failure(error)

    [record] = records(caplog)
    assert record.levelno == logging.WARNING
    assert f"error={type(error).__name__} reason={error.reason} " in record.getMessage()


def test_not_configured_logs_at_info(caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.DEBUG, logger="jarvis.assistant")

    failure(FoundryNotConfiguredError())

    [record] = records(caplog)
    assert record.levelno == logging.INFO
    assert record.getMessage() == (
        "assistant request failed: error=FoundryNotConfiguredError reason=not_configured "
        f"status_code=None request_id=None input_length={len(MESSAGE)}"
    )


def test_log_never_contains_private_data(caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.DEBUG)
    error = FoundryUnavailableError(reason="unauthorized", status_code=401, request_id="req-9")
    # Even if an upstream error object were to carry secrets as extra attributes.
    error.args = SECRETS

    failure(error)

    logged = caplog.text + repr([vars(r) for r in caplog.records])
    for secret in SECRETS:
        assert secret not in logged
    assert "private-user@example.com" not in logged


@pytest.mark.parametrize(
    ("reason", "request_id", "expected"),
    [
        (
            "status_in_progress",
            "abc-123_x.y:z",
            "reason=status_in_progress status_code=None request_id=abc-123_x.y:z",
        ),
        ("status_evil\nINJECTED", "req-1", "reason=invalid status_code=None request_id=req-1"),
        (
            "forbidden",
            "req\nINJECTED log line",
            "reason=forbidden status_code=None request_id=invalid",
        ),
        ("forbidden", "x" * 129, "reason=forbidden status_code=None request_id=invalid"),
    ],
)
def test_log_fields_are_sanitised(
    caplog: pytest.LogCaptureFixture, reason: str, request_id: str, expected: str
) -> None:
    caplog.set_level(logging.DEBUG, logger="jarvis.assistant")

    failure(FoundryUnavailableError(reason=reason, request_id=request_id))

    [record] = records(caplog)
    assert expected in record.getMessage()
    assert "INJECTED" not in record.getMessage()
