"""HTTP translation of domain errors, plus response hardening for private endpoints."""

from collections.abc import Awaitable, Callable

from fastapi import FastAPI, Request, Response, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from app.services.assistant_errors import (
    AssistantBusyError,
    AssistantError,
    AssistantNotConfiguredError,
    AssistantRequestRejectedError,
    AssistantTimeoutError,
    AssistantUnavailableError,
)
from app.services.auth_errors import (
    AccountDisabledError,
    AuthError,
    EmailAlreadyRegisteredError,
    InvalidCredentialsError,
    InvalidPasswordError,
    InvalidSessionError,
    RegistrationDisabledError,
)

AUTH_ERROR_STATUS: dict[type[AuthError], int] = {
    RegistrationDisabledError: status.HTTP_403_FORBIDDEN,
    InvalidPasswordError: status.HTTP_422_UNPROCESSABLE_CONTENT,
    EmailAlreadyRegisteredError: status.HTTP_409_CONFLICT,
    InvalidCredentialsError: status.HTTP_401_UNAUTHORIZED,
    AccountDisabledError: status.HTTP_403_FORBIDDEN,
    InvalidSessionError: status.HTTP_401_UNAUTHORIZED,
}

ASSISTANT_ERROR_STATUS: dict[type[AssistantError], int] = {
    AssistantNotConfiguredError: status.HTTP_503_SERVICE_UNAVAILABLE,
    AssistantUnavailableError: status.HTTP_503_SERVICE_UNAVAILABLE,
    AssistantTimeoutError: status.HTTP_504_GATEWAY_TIMEOUT,
    AssistantBusyError: status.HTTP_429_TOO_MANY_REQUESTS,
    AssistantRequestRejectedError: status.HTTP_422_UNPROCESSABLE_CONTENT,
}

# Responses under these prefixes carry tokens, user data or assistant conversations.
NO_STORE_PATH_PREFIXES = ("/api/auth", "/api/assistant")


async def handle_auth_error(_request: Request, exc: AuthError) -> JSONResponse:
    status_code = AUTH_ERROR_STATUS[type(exc)]
    # RFC 9110 requires WWW-Authenticate on 401. No error="invalid_token" attribute, so
    # a missing token and an invalid one stay indistinguishable.
    headers = {"WWW-Authenticate": "Bearer"} if status_code == 401 else None
    # Domain error messages are fixed, generic strings without user data.
    return JSONResponse({"detail": str(exc)}, status_code=status_code, headers=headers)


async def handle_assistant_error(_request: Request, exc: AssistantError) -> JSONResponse:
    headers = None
    if isinstance(exc, AssistantBusyError) and exc.retry_after_seconds is not None:
        headers = {"Retry-After": str(exc.retry_after_seconds)}
    # Fixed, generic messages: no user message, reply or Foundry details.
    return JSONResponse(
        {"detail": str(exc)}, status_code=ASSISTANT_ERROR_STATUS[type(exc)], headers=headers
    )


async def handle_validation_error(_request: Request, exc: RequestValidationError) -> JSONResponse:
    """Like FastAPI's default 422, but never echoes submitted values back.

    The default includes each error's "input" (and "ctx"), which can contain
    passwords, emails, tokens or raw request bodies.
    """
    errors = [
        {"loc": error["loc"], "msg": error["msg"], "type": error["type"]} for error in exc.errors()
    ]
    return JSONResponse({"detail": errors}, status_code=status.HTTP_422_UNPROCESSABLE_CONTENT)


async def no_store_for_private_paths(
    request: Request, call_next: Callable[[Request], Awaitable[Response]]
) -> Response:
    """Prevent any cache from storing auth or assistant responses, including errors."""
    response = await call_next(request)
    if request.url.path.startswith(NO_STORE_PATH_PREFIXES):
        response.headers["Cache-Control"] = "no-store"
    return response


def register_error_handlers(app: FastAPI) -> None:
    app.add_exception_handler(AuthError, handle_auth_error)
    app.add_exception_handler(AssistantError, handle_assistant_error)
    app.add_exception_handler(RequestValidationError, handle_validation_error)
    app.middleware("http")(no_store_for_private_paths)
