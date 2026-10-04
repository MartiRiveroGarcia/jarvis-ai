from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict
from sqlalchemy.engine import make_url
from sqlalchemy.exc import ArgumentError

# Resolve backend/.env from this file's location so settings load the same way
# regardless of the directory uvicorn or pytest is started from.
BACKEND_DIR = Path(__file__).resolve().parents[2]

Environment = Literal["development", "test", "production"]


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

    # May contain credentials (e.g. PostgreSQL), so it is excluded from repr.
    database_url: str = Field(
        default=f"sqlite:///{BACKEND_DIR / 'jarvis.db'}",
        validation_alias="DATABASE_URL",
        repr=False,
    )

    @field_validator("database_url")
    @classmethod
    def validate_database_url(cls, value: str) -> str:
        try:
            make_url(value)
        except ArgumentError:
            # Do not echo the value: it may contain a password.
            raise ValueError("DATABASE_URL is not a valid SQLAlchemy database URL") from None
        return value


@lru_cache
def get_settings() -> Settings:
    """Return the shared settings instance, created on first use."""
    return Settings()
