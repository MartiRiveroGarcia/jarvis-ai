"""The basic Jarvis assistant: one stateless request, one model reply.

There is no history, memory, persistence or conversation id: each call sends the
fixed Jarvis instruction plus the user's message and returns the reply.
"""

import logging
import math
import re
from collections.abc import Callable
from typing import Protocol

from app.integrations.foundry.errors import (
    FoundryError,
    FoundryNotConfiguredError,
    FoundryRateLimitedError,
    FoundryRejectedError,
    FoundryTimeoutError,
)
from app.models.user import User
from app.services.assistant_errors import (
    AssistantBusyError,
    AssistantError,
    AssistantNotConfiguredError,
    AssistantRequestRejectedError,
    AssistantTimeoutError,
    AssistantUnavailableError,
)

JARVIS_INSTRUCTIONS = "You are Jarvis, a concise and helpful personal assistant."

# Upper bound for the Retry-After hint passed on to clients.
MAX_RETRY_AFTER_SECONDS = 120

logger = logging.getLogger("jarvis.assistant")

# Request ids come from an upstream header and some reasons embed an upstream status:
# only log values that look like what they claim to be.
_SAFE_REQUEST_ID = re.compile(r"[A-Za-z0-9._:-]{1,128}")
_SAFE_REASON = re.compile(r"[a-z0-9_]{1,64}")


class ResponseGenerator(Protocol):
    """Anything that turns an instruction and a user message into a text reply."""

    def generate(self, *, instructions: str, user_input: str) -> str: ...


# Returns the generator; may raise FoundryNotConfiguredError.
GeneratorProvider = Callable[[], ResponseGenerator]


class AssistantService:
    def __init__(self, generator_provider: GeneratorProvider) -> None:
        self._generator_provider = generator_provider

    def respond(self, user: User, message: str) -> str:
        """Return the assistant's reply to one message.

        `user` is the authenticated caller. It is not used yet (no per-user state)
        and is never sent upstream.
        """
        try:
            generator = self._generator_provider()
            return generator.generate(instructions=JARVIS_INSTRUCTIONS, user_input=message)
        except FoundryError as error:
            _log_failure(error, input_length=len(message))
            raise _to_domain_error(error) from None


def _to_domain_error(error: FoundryError) -> AssistantError:
    if isinstance(error, FoundryNotConfiguredError):
        return AssistantNotConfiguredError()
    if isinstance(error, FoundryTimeoutError):
        return AssistantTimeoutError()
    if isinstance(error, FoundryRateLimitedError):
        return AssistantBusyError(_retry_after_seconds(error.retry_after))
    if isinstance(error, FoundryRejectedError):
        return AssistantRequestRejectedError()
    # FoundryUnavailableError, FoundryBadResponseError and any future subclass.
    return AssistantUnavailableError()


def _retry_after_seconds(retry_after: float | None) -> int | None:
    if retry_after is None or math.isnan(retry_after) or retry_after < 0:
        return None
    return math.ceil(min(retry_after, MAX_RETRY_AFTER_SECONDS))


def _log_failure(error: FoundryError, *, input_length: int) -> None:
    """Log one line of content-free metadata; never the message, reply or SDK details."""
    # Not being configured is a local state, not an upstream fault.
    level = logging.INFO if isinstance(error, FoundryNotConfiguredError) else logging.WARNING
    reason = error.reason if _SAFE_REASON.fullmatch(error.reason) else "invalid"
    request_id = error.request_id
    if request_id is not None and not _SAFE_REQUEST_ID.fullmatch(request_id):
        request_id = "invalid"
    logger.log(
        level,
        "assistant request failed: error=%s reason=%s status_code=%s request_id=%s input_length=%d",
        type(error).__name__,
        reason,
        error.status_code,
        request_id,
        input_length,
    )
