"""Shared FastAPI dependencies."""

from functools import lru_cache
from typing import Annotated

from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from app.config.settings import Settings, get_settings
from app.database.session import get_db
from app.integrations.foundry import FoundryResponsesClient
from app.models.user import User
from app.security.session_tokens import is_well_formed_session_token
from app.services.assistant_service import AssistantService
from app.services.auth_errors import InvalidSessionError
from app.services.auth_service import AuthService

# auto_error=False: every failure is turned into the same generic 401 by our handler.
bearer_scheme = HTTPBearer(
    auto_error=False,
    description="Opaque session token returned by POST /api/auth/login (not a JWT).",
)


def get_auth_service(
    db: Annotated[Session, Depends(get_db)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> AuthService:
    """One AuthService per request, sharing the request's database session."""
    return AuthService(
        db,
        session_ttl=settings.session_ttl,
        registration_enabled=settings.registration_enabled,
    )


def get_bearer_token(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)],
) -> str | None:
    """Return the Bearer token only if it is well formed; otherwise None.

    Missing headers, other schemes and malformed tokens are indistinguishable, and
    none of them ever reach the database.
    """
    if credentials is None or not is_well_formed_session_token(credentials.credentials):
        return None
    return credentials.credentials


def get_current_user(
    token: Annotated[str | None, Depends(get_bearer_token)],
    auth_service: Annotated[AuthService, Depends(get_auth_service)],
) -> User:
    if token is None:
        raise InvalidSessionError
    return auth_service.authenticate(token)


@lru_cache
def get_foundry_client() -> FoundryResponsesClient:
    """Return the process-wide Foundry client, created on the first assistant request.

    Construction only stores configuration; the Entra ID credential and the SDK client
    are created inside the client on its first call, then reused. Raises
    FoundryNotConfiguredError (never cached) when Foundry is not configured.
    """
    return FoundryResponsesClient.from_settings(get_settings())


def get_assistant_service() -> AssistantService:
    # The provider is only called inside AssistantService.respond(), so neither app
    # startup nor any other endpoint touches Foundry.
    return AssistantService(generator_provider=get_foundry_client)
