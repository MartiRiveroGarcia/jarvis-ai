import re
from datetime import timedelta
from functools import lru_cache
from pathlib import Path
from typing import Literal, Self
from urllib.parse import urlsplit, urlunsplit

from pydantic import Field, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict
from sqlalchemy.engine import make_url
from sqlalchemy.exc import ArgumentError

# Resolve backend/.env from this file's location so settings load the same way
# regardless of the directory uvicorn or pytest is started from.
BACKEND_DIR = Path(__file__).resolve().parents[2]

Environment = Literal["development", "test", "production"]

# A Foundry project endpoint path: /api/projects/<project>, one URL-safe segment.
_FOUNDRY_PROJECT_PATH = re.compile(r"/api/projects/(?!\.{1,2}$)[A-Za-z0-9._~-]+")
# Azure deployment names: letters, digits, dots, hyphens and underscores.
_FOUNDRY_DEPLOYMENT_NAME = re.compile(r"[A-Za-z0-9._-]{1,64}")


class Settings(BaseSettings):
    """Application settings, read from JARVIS_-prefixed environment variables.

    DATABASE_URL is the one exception: it keeps its conventional unprefixed name.
    """

    model_config = SettingsConfigDict(
        env_prefix="JARVIS_",
        env_file=BACKEND_DIR / ".env",
        env_file_encoding="utf-8",
        extra="ignore",
        # Settings may hold credentials; keep raw values out of validation errors.
        hide_input_in_errors=True,
    )

    app_name: str = "Jarvis API"
    environment: Environment = "development"

    # Fixed session lifetime (no sliding renewal).
    session_ttl_days: int = Field(default=7, ge=1, le=90)
    # Allow public sign-up. Create your own account, then disable it in production.
    registration_enabled: bool = True

    # May contain credentials (e.g. PostgreSQL), so it is excluded from repr.
    database_url: str = Field(
        default=f"sqlite:///{BACKEND_DIR / 'jarvis.db'}",
        validation_alias="DATABASE_URL",
        repr=False,
    )

    # Microsoft Foundry (optional). Endpoint and model must be set together; with
    # neither, the backend runs without the assistant. Access uses Microsoft Entra
    # ID, so there is deliberately no API key setting.
    # Not a credential, but kept out of repr so it does not end up in logs.
    foundry_project_endpoint: str | None = Field(default=None, repr=False)
    # The deployment name used in Responses API calls; never hard-coded.
    foundry_model: str | None = None
    foundry_timeout_seconds: int = Field(default=25, ge=1, le=120)
    foundry_max_output_tokens: int = Field(default=2000, ge=16, le=16384)

    @field_validator("database_url")
    @classmethod
    def validate_database_url(cls, value: str) -> str:
        try:
            make_url(value)
        except ArgumentError:
            # Do not echo the value: it may contain a password.
            raise ValueError("DATABASE_URL is not a valid SQLAlchemy database URL") from None
        return value

    @field_validator("foundry_project_endpoint")
    @classmethod
    def validate_foundry_project_endpoint(cls, value: str | None) -> str | None:
        """Accept only an https Foundry project endpoint; never echo the value."""
        if value is None:
            return None
        message = "JARVIS_FOUNDRY_PROJECT_ENDPOINT"
        try:
            parts = urlsplit(value.strip())
            parts.port  # noqa: B018 - raises ValueError for an invalid port
        except ValueError:
            raise ValueError(f"{message} is not a valid URL") from None
        if parts.scheme.lower() != "https":
            raise ValueError(f"{message} must be an absolute https URL")
        if not parts.hostname:
            raise ValueError(f"{message} must include a host")
        if parts.username is not None or parts.password is not None:
            raise ValueError(f"{message} must not contain credentials")
        if parts.query or parts.fragment or "?" in value or "#" in value:
            raise ValueError(f"{message} must not contain a query or fragment")
        path = parts.path.rstrip("/")
        if not _FOUNDRY_PROJECT_PATH.fullmatch(path):
            raise ValueError(f"{message} must be a project endpoint (/api/projects/<project>)")
        # Scheme and host are case-insensitive; the path is kept as written.
        return urlunsplit(("https", parts.netloc.lower(), path, "", ""))

    @field_validator("foundry_model")
    @classmethod
    def validate_foundry_model(cls, value: str | None) -> str | None:
        if value is None:
            return None
        name = value.strip()
        if not _FOUNDRY_DEPLOYMENT_NAME.fullmatch(name):
            raise ValueError(
                "JARVIS_FOUNDRY_MODEL must be a deployment name of 1-64 letters, "
                "digits, dots, hyphens or underscores"
            )
        return name

    @model_validator(mode="after")
    def _foundry_settings_are_complete(self) -> Self:
        if (self.foundry_project_endpoint is None) != (self.foundry_model is None):
            raise ValueError(
                "JARVIS_FOUNDRY_PROJECT_ENDPOINT and JARVIS_FOUNDRY_MODEL must be set together"
            )
        return self

    @property
    def session_ttl(self) -> timedelta:
        return timedelta(days=self.session_ttl_days)

    @property
    def foundry_configured(self) -> bool:
        return self.foundry_project_endpoint is not None and self.foundry_model is not None


@lru_cache
def get_settings() -> Settings:
    """Return the shared settings instance, created on first use."""
    return Settings()
