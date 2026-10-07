"""HTTP translation of domain errors, plus response hardening for auth endpoints."""

from collections.abc import Awaitable, Callable

from fastapi import FastAPI, Request, Response, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

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

AUTH_PATH_PREFIX = "/api/auth"


async def handle_auth_error(_request: Request, exc: AuthError) -> JSONResponse:
    status_code = AUTH_ERROR_STATUS[type(exc)]
    # RFC 9110 requires WWW-Authenticate on 401. No error="invalid_token" attribute, so
    # a missing token and an invalid one stay indistinguishable.
    headers = {"WWW-Authenticate": "Bearer"} if status_code == 401 else None
    # Domain error messages are fixed, generic strings without user data.
    return JSONResponse({"detail": str(exc)}, status_code=status_code, headers=headers)


async def handle_validation_error(_request: Request, exc: RequestValidationError) -> JSONResponse:
    """Like FastAPI's default 422, but never echoes submitted values back.

    The default includes each error's "input" (and "ctx"), which can contain
    passwords, emails, tokens or raw request bodies.
    """
    errors = [
        {"loc": error["loc"], "msg": error["msg"], "type": error["type"]} for error in exc.errors()
    ]
    return JSONResponse({"detail": errors}, status_code=status.HTTP_422_UNPROCESSABLE_CONTENT)


async def no_store_for_auth(
    request: Request, call_next: Callable[[Request], Awaitable[Response]]
) -> Response:
    """Prevent any cache from storing auth responses (tokens, user data, errors)."""
    response = await call_next(request)
    if request.url.path.startswith(AUTH_PATH_PREFIX):
        response.headers["Cache-Control"] = "no-store"
    return response


def register_error_handlers(app: FastAPI) -> None:
    app.add_exception_handler(AuthError, handle_auth_error)
    app.add_exception_handler(RequestValidationError, handle_validation_error)
    app.middleware("http")(no_store_for_auth)
