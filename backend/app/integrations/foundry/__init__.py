"""Microsoft Foundry integration (Responses API on a Foundry project endpoint)."""

from app.integrations.foundry.errors import (
    FoundryBadResponseError,
    FoundryError,
    FoundryNotConfiguredError,
    FoundryRateLimitedError,
    FoundryRejectedError,
    FoundryTimeoutError,
    FoundryUnavailableError,
)
from app.integrations.foundry.responses_client import (
    DEFAULT_REASONING_EFFORT,
    FOUNDRY_TOKEN_SCOPE,
    FoundryResponsesClient,
)

__all__ = [
    "DEFAULT_REASONING_EFFORT",
    "FOUNDRY_TOKEN_SCOPE",
    "FoundryBadResponseError",
    "FoundryError",
    "FoundryNotConfiguredError",
    "FoundryRateLimitedError",
    "FoundryRejectedError",
    "FoundryResponsesClient",
    "FoundryTimeoutError",
    "FoundryUnavailableError",
]
