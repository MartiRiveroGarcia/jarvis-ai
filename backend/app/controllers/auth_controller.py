from typing import Annotated

from fastapi import APIRouter, Depends, Response, status

from app.dependencies import get_auth_service, get_bearer_token, get_current_user
from app.models.user import User
from app.schemas.auth import LoginRequest, LoginResponse, RegisterRequest, UserResponse
from app.services.auth_service import AuthService

router = APIRouter(prefix="/auth", tags=["auth"])

AuthServiceDep = Annotated[AuthService, Depends(get_auth_service)]


@router.post("/register", status_code=status.HTTP_201_CREATED)
def register(body: RegisterRequest, auth_service: AuthServiceDep) -> UserResponse:
    """Create an account. Does not log in: call /login afterwards."""
    user = auth_service.register(body.email, body.password)
    return UserResponse.model_validate(user)


@router.post("/login")
def login(body: LoginRequest, auth_service: AuthServiceDep) -> LoginResponse:
    """Return a new opaque session token. It is only ever returned here."""
    result = auth_service.login(body.email, body.password)
    return LoginResponse(
        user=UserResponse.model_validate(result.user),
        session_token=result.session_token,
        expires_at=result.expires_at,
    )


@router.get("/me")
def me(user: Annotated[User, Depends(get_current_user)]) -> UserResponse:
    return UserResponse.model_validate(user)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
def logout(
    token: Annotated[str | None, Depends(get_bearer_token)],
    auth_service: AuthServiceDep,
) -> Response:
    """Revoke the session. Idempotent: always 204, even without valid credentials."""
    if token is not None:
        auth_service.logout(token)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
