"""Shared FastAPI dependencies."""

from typing import Annotated

from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from app.config.settings import Settings, get_settings
from app.database.session import get_db
from app.models.user import User
from app.security.session_tokens import is_well_formed_session_token
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
