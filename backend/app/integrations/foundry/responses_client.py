"""Client for the Microsoft Foundry project Responses API.

One stateless request per call: no conversation state, no tools, no streaming and
`store=False`, so nothing is kept upstream. Authentication uses Microsoft Entra ID
(DefaultAzureCredential: Azure CLI locally, managed identity in Azure); there are
no API keys.
"""

import threading
from collections.abc import Callable
from typing import TYPE_CHECKING

import httpx2
import openai
from openai import OpenAI
from openai.types.responses import Response

from app.integrations.foundry.errors import (
    FoundryBadResponseError,
    FoundryError,
    FoundryNotConfiguredError,
    FoundryRateLimitedError,
    FoundryRejectedError,
    FoundryTimeoutError,
    FoundryUnavailableError,
)

if TYPE_CHECKING:
    from app.config.settings import Settings

FOUNDRY_TOKEN_SCOPE = "https://ai.azure.com/.default"
DEFAULT_REASONING_EFFORT = "low"

TokenProvider = Callable[[], str]


class FoundryResponsesClient:
    """Calls `{project_endpoint}/openai/v1/responses` for one configured deployment.

    Constructing the client stores configuration only. The Entra ID credential and
    the SDK client are created on the first `generate()` call.
    """

    def __init__(
        self,
        *,
        project_endpoint: str,
        deployment: str,
        timeout_seconds: float,
        max_output_tokens: int,
        reasoning_effort: str | None = DEFAULT_REASONING_EFFORT,
        token_provider: TokenProvider | None = None,
        http_client: httpx2.Client | None = None,
    ) -> None:
        self._base_url = project_endpoint.rstrip("/") + "/openai/v1"
        self._deployment = deployment
        self._timeout_seconds = timeout_seconds
        self._max_output_tokens = max_output_tokens
        self._reasoning_effort = reasoning_effort
        self._token_provider = token_provider
        self._http_client = http_client
        self._client: OpenAI | None = None
        self._lock = threading.Lock()

    @classmethod
    def from_settings(cls, settings: "Settings") -> "FoundryResponsesClient":
        if settings.foundry_project_endpoint is None or settings.foundry_model is None:
            raise FoundryNotConfiguredError
        return cls(
            project_endpoint=settings.foundry_project_endpoint,
            deployment=settings.foundry_model,
            timeout_seconds=settings.foundry_timeout_seconds,
            max_output_tokens=settings.foundry_max_output_tokens,
        )

    def __repr__(self) -> str:
        # Never expose the endpoint or deployment name.
        return f"{type(self).__name__}(initialized={self._client is not None})"

    def generate(self, *, instructions: str, user_input: str) -> str:
        """Return the model's text reply. Raises a FoundryError subclass on failure."""
        client = self._get_client()
        request: dict[str, object] = {
            "model": self._deployment,
            "instructions": instructions,
            "input": user_input,
            "store": False,
            "max_output_tokens": self._max_output_tokens,
        }
        if self._reasoning_effort is not None:
            request["reasoning"] = {"effort": self._reasoning_effort}

        try:
            response = client.responses.create(**request)  # type: ignore[call-overload]
        except FoundryError:
            raise  # from the guarded token provider
        except openai.APITimeoutError:
            raise FoundryTimeoutError(reason="timeout") from None
        except openai.APIConnectionError:
            raise FoundryUnavailableError(reason="connection") from None
        except openai.APIStatusError as error:
            raise _translate_status_error(error) from None
        except openai.APIResponseValidationError as error:
            raise FoundryBadResponseError(
                reason="malformed", status_code=error.status_code
            ) from None
        except openai.OpenAIError:
            raise FoundryUnavailableError(reason="sdk_error") from None
        except (ValueError, TypeError):
            # The SDK parses leniently: invalid JSON or missing fields surface raw.
            raise FoundryBadResponseError(reason="malformed") from None

        return _extract_text(response)

    def _get_client(self) -> OpenAI:
        if self._client is None:
            with self._lock:
                if self._client is None:
                    self._client = OpenAI(
                        base_url=self._base_url,
                        api_key=_guarded(self._token_provider or _entra_token_provider()),
                        timeout=self._timeout_seconds,
                        max_retries=0,  # one Jarvis request = one upstream attempt
                        http_client=self._http_client,
                    )
        return self._client


def _entra_token_provider() -> TokenProvider:
    """Create the Entra ID token provider. Imported and built only on first use."""
    try:
        from azure.identity import DefaultAzureCredential, get_bearer_token_provider

        return get_bearer_token_provider(DefaultAzureCredential(), FOUNDRY_TOKEN_SCOPE)
    except Exception:
        raise FoundryUnavailableError(reason="credential") from None


def _guarded(provider: TokenProvider) -> TokenProvider:
    """The SDK does not wrap token-provider failures; hide raw Azure error details."""

    def get_token() -> str:
        try:
            return provider()
        except Exception:
            raise FoundryUnavailableError(reason="credential") from None

    return get_token


_STATUS_REASONS = {401: "unauthorized", 403: "forbidden", 404: "not_found"}


def _translate_status_error(error: openai.APIStatusError) -> FoundryError:
    status, request_id = error.status_code, error.request_id
    if status == 429:
        return FoundryRateLimitedError(
            status_code=status,
            request_id=request_id,
            retry_after=_retry_after_seconds(error.response.headers.get("retry-after")),
        )
    if status == 400 and error.code == "content_filter":
        return FoundryRejectedError(
            reason="content_filter", status_code=status, request_id=request_id
        )
    if status in (400, 422):
        reason = "bad_request"  # our request or configuration is wrong, not the user's input
    elif status >= 500:
        reason = "server_error"
    else:
        reason = _STATUS_REASONS.get(status, "unexpected_status")
    return FoundryUnavailableError(reason=reason, status_code=status, request_id=request_id)


def _retry_after_seconds(value: str | None) -> float | None:
    try:
        seconds = float(value) if value is not None else None
    except ValueError:
        return None
    return seconds if seconds is not None and seconds >= 0 else None


def _extract_text(response: object) -> str:
    if not isinstance(response, Response):
        raise FoundryBadResponseError(reason="malformed")
    try:
        status = response.status
        incomplete_reason = (
            response.incomplete_details.reason if response.incomplete_details else None
        )
        text = response.output_text.strip()
        refused = any(
            content.type == "refusal"
            for item in response.output
            if item.type == "message"
            for content in item.content
        )
    except Exception:
        raise FoundryBadResponseError(reason="malformed") from None

    if status != "completed":
        if status == "incomplete" and incomplete_reason == "content_filter":
            raise FoundryRejectedError(reason="content_filter")
        if status == "incomplete" and incomplete_reason == "max_output_tokens":
            raise FoundryBadResponseError(reason="incomplete_max_output_tokens")
        raise FoundryBadResponseError(reason=f"status_{status}")
    if not text:
        if refused:
            raise FoundryRejectedError(reason="refusal")
        raise FoundryBadResponseError(reason="empty_output")
    return text
