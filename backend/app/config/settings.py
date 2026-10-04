from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict

# Resolve backend/.env from this file's location so settings load the same way
# regardless of the directory uvicorn or pytest is started from.
BACKEND_DIR = Path(__file__).resolve().parents[2]

Environment = Literal["development", "test", "production"]


class Settings(BaseSettings):
    """Application settings, read from environment variables prefixed with JARVIS_."""

    model_config = SettingsConfigDict(
        env_prefix="JARVIS_",
        env_file=BACKEND_DIR / ".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    app_name: str = "Jarvis API"
    environment: Environment = "development"


@lru_cache
def get_settings() -> Settings:
    """Return the shared settings instance, created on first use."""
    return Settings()
