"""Domain errors raised by AssistantService.

Messages are fixed and generic: they never include the user's message, the reply,
Foundry details, the endpoint or the deployment name. Controllers translate these
into HTTP responses.
"""


class AssistantError(Exception):
    """Base class for assistant failures."""

    message = "The assistant failed"

    def __init__(self) -> None:
        super().__init__(self.message)


class AssistantNotConfiguredError(AssistantError):
    message = "The assistant is not available"


class AssistantUnavailableError(AssistantError):
    message = "The assistant is temporarily unavailable"


class AssistantTimeoutError(AssistantError):
    message = "The assistant took too long to respond"


class AssistantBusyError(AssistantError):
    message = "The assistant is busy. Please try again shortly"

    def __init__(self, retry_after_seconds: int | None = None) -> None:
        super().__init__()
        # Whole seconds, already capped; None when the upstream gave no usable hint.
        self.retry_after_seconds = retry_after_seconds


class AssistantRequestRejectedError(AssistantError):
    message = "The assistant couldn't answer that request"
