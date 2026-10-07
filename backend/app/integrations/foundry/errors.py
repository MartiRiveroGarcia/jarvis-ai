"""Errors raised by the Microsoft Foundry integration.

They carry only a fixed message plus diagnostic metadata that contains no user
content or secrets: a short reason code, the upstream HTTP status, Foundry's request
id and, for rate limiting, the suggested retry delay. They never include SDK
messages, the endpoint, the deployment name, tokens, input or output text.
"""


class FoundryError(Exception):
    message = "Foundry request failed"

    def __init__(
        self,
        *,
        reason: str,
        status_code: int | None = None,
        request_id: str | None = None,
    ) -> None:
        super().__init__(self.message)
        self.reason = reason
        self.status_code = status_code
        self.request_id = request_id

    def __str__(self) -> str:
        status = f", status {self.status_code}" if self.status_code is not None else ""
        return f"{self.message} ({self.reason}{status})"

    def __repr__(self) -> str:
        return f"{type(self).__name__}(reason={self.reason!r}, status_code={self.status_code!r})"


class FoundryNotConfiguredError(FoundryError):
    """Local state: no Foundry endpoint/deployment is configured. Not an upstream failure."""

    message = "Foundry is not configured"

    def __init__(self) -> None:
        super().__init__(reason="not_configured")


class FoundryTimeoutError(FoundryError):
    message = "Foundry did not respond in time"


class FoundryUnavailableError(FoundryError):
    """Foundry could not be used: connection, credential, auth, configuration or 5xx."""

    message = "Foundry is unavailable"


class FoundryRateLimitedError(FoundryError):
    message = "Foundry rate limit reached"

    def __init__(
        self,
        *,
        status_code: int | None = None,
        request_id: str | None = None,
        retry_after: float | None = None,
    ) -> None:
        super().__init__(reason="rate_limited", status_code=status_code, request_id=request_id)
        self.retry_after = retry_after


class FoundryRejectedError(FoundryError):
    """The request was refused because of its content (content filter or refusal)."""

    message = "Foundry rejected the request"


class FoundryBadResponseError(FoundryError):
    """A response arrived but is unusable: not completed, empty or malformed."""

    message = "Foundry returned an unusable response"
