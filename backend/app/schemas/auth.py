import uuid
from datetime import datetime
from typing import Annotated, Literal

from pydantic import (
    BaseModel,
    ConfigDict,
    EmailStr,
    Field,
    SecretStr,
    WithJsonSchema,
    field_serializer,
)

from app.models.user import EMAIL_MAX_LENGTH
from app.security.password_policy import (
    MAX_LOGIN_PASSWORD_LENGTH,
    MAX_PASSWORD_LENGTH,
    MIN_PASSWORD_LENGTH,
)

# Matches the users.email column, independently of email-validator's own limits.
RegistrationEmail = Annotated[EmailStr, Field(max_length=EMAIL_MAX_LENGTH)]


class RegisterRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    email: RegistrationEmail
    password: str = Field(min_length=MIN_PASSWORD_LENGTH, max_length=MAX_PASSWORD_LENGTH)


class LoginRequest(BaseModel):
    """Deliberately looser than RegisterRequest.

    Login must keep working for existing accounts if the email or password rules
    become stricter later; malformed values simply fail as invalid credentials.
    """

    model_config = ConfigDict(extra="forbid")

    email: str = Field(min_length=1, max_length=EMAIL_MAX_LENGTH)
    password: str = Field(min_length=1, max_length=MAX_LOGIN_PASSWORD_LENGTH)


class UserResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    email: str
    created_at: datetime


class LoginResponse(BaseModel):
    user: UserResponse
    # SecretStr keeps the token out of repr/str/logs; it is only revealed when the
    # response is serialised to JSON. Documented as a plain string (not writeOnly).
    session_token: Annotated[
        SecretStr,
        WithJsonSchema(
            {"type": "string", "description": "Opaque session token; send as a Bearer credential"}
        ),
    ]
    token_type: Literal["bearer"] = "bearer"
    expires_at: datetime

    @field_serializer("session_token", when_used="json")
    def _reveal_session_token(self, token: SecretStr) -> str:
        return token.get_secret_value()
