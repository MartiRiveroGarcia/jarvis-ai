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
# An Azure Speech custom-domain host: exactly one DNS label before the suffix.
# Microsoft Entra ID authentication requires the custom domain.
_SPEECH_CUSTOM_DOMAIN_HOST = re.compile(
    r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.cognitiveservices\.azure\.com"
)
# Speech locales such as ca-ES, en-US or zh-Hans-CN.
_SPEECH_LOCALE = re.compile(r"[a-z]{2,3}(?:-[A-Z][a-z]{3})?-[A-Z]{2}")
# At-start language identification accepts at most four candidate languages.
MAX_SPEECH_RECOGNITION_LANGUAGES = 4
# Voice names such as ca-ES-AlbaNeural or en-US-Ava:DragonHDLatestNeural. The
# restricted alphabet also keeps the name safe to place in an SSML attribute.
_SPEECH_VOICE = re.compile(r"[a-z]{2,3}(?:-[A-Z][a-z]{3})?-[A-Z]{2}-[A-Za-z0-9:]{1,64}")


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

    # Azure AI Speech (optional): speech-to-text and text-to-speech. Unset endpoint
    # means Speech is disabled. Microsoft Entra ID only, through the resource's
    # custom domain; there is deliberately no key or region setting.
    # Not a credential, but kept out of repr so it does not end up in logs.
    speech_endpoint: str | None = Field(default=None, repr=False)
    # Spoken languages to recognise, in order. One locale: fixed-language recognition.
    # Two to four: the service identifies which one is spoken at the start of each
    # recording. Set as JSON, e.g. JARVIS_SPEECH_RECOGNITION_LANGUAGES='["ca-ES"]'.
    speech_recognition_languages: tuple[str, ...] = ("ca-ES", "es-ES", "en-US", "zh-CN")
    # Removed: replaced by speech_recognition_languages. Declared only so that a
    # leftover value stops startup instead of being silently ignored.
    speech_recognition_language: str | None = Field(default=None, exclude=True, repr=False)
    speech_voice: str = "ca-ES-AlbaNeural"
    speech_stt_timeout_seconds: int = Field(default=45, ge=1, le=120)
    speech_tts_timeout_seconds: int = Field(default=20, ge=1, le=120)

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

    @field_validator("speech_endpoint")
    @classmethod
    def validate_speech_endpoint(cls, value: str | None) -> str | None:
        """Accept only an https Speech custom-domain endpoint; never echo the value."""
        if value is None:
            return None
        message = "JARVIS_SPEECH_ENDPOINT"
        try:
            parts = urlsplit(value.strip())
            port = parts.port
        except ValueError:
            raise ValueError(f"{message} is not a valid URL") from None
        if parts.scheme.lower() != "https":
            raise ValueError(f"{message} must be an absolute https URL")
        if parts.username is not None or parts.password is not None:
            raise ValueError(f"{message} must not contain credentials")
        if parts.query or parts.fragment or "?" in value or "#" in value:
            raise ValueError(f"{message} must not contain a query or fragment")
        if parts.path not in ("", "/"):
            raise ValueError(f"{message} must not contain a path")
        host = (parts.hostname or "").lower()
        if not _SPEECH_CUSTOM_DOMAIN_HOST.fullmatch(host) or port not in (None, 443):
            raise ValueError(
                f"{message} must be a custom-domain endpoint "
                "(https://<name>.cognitiveservices.azure.com)"
            )
        return f"https://{host}"

    @field_validator("speech_recognition_languages")
    @classmethod
    def validate_speech_recognition_languages(cls, value: tuple[str, ...]) -> tuple[str, ...]:
        """1-4 distinct locales, at most one per language; never echo the values."""
        name = "JARVIS_SPEECH_RECOGNITION_LANGUAGES"
        locales = tuple(locale.strip() for locale in value)
        if not 1 <= len(locales) <= MAX_SPEECH_RECOGNITION_LANGUAGES:
            raise ValueError(f"{name} must list 1 to {MAX_SPEECH_RECOGNITION_LANGUAGES} locales")
        if not all(_SPEECH_LOCALE.fullmatch(locale) for locale in locales):
            raise ValueError(f"{name} must contain locales such as ca-ES or en-US")
        # Language identification must not choose between variants of one language.
        bases = [locale.split("-", 1)[0] for locale in locales]
        if len(set(bases)) != len(bases):
            raise ValueError(f"{name} must not list the same language twice")
        return locales

    @field_validator("speech_recognition_language")
    @classmethod
    def reject_removed_speech_recognition_language(cls, value: str | None) -> None:
        if value is not None:
            raise ValueError(
                "JARVIS_SPEECH_RECOGNITION_LANGUAGE was replaced by "
                "JARVIS_SPEECH_RECOGNITION_LANGUAGES (a JSON list of locales)"
            )

    @field_validator("speech_voice")
    @classmethod
    def validate_speech_voice(cls, value: str) -> str:
        voice = value.strip()
        if not _SPEECH_VOICE.fullmatch(voice):
            raise ValueError("JARVIS_SPEECH_VOICE must be a voice name such as ca-ES-AlbaNeural")
        return voice

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

    @property
    def speech_configured(self) -> bool:
        return self.speech_endpoint is not None


@lru_cache
def get_settings() -> Settings:
    """Return the shared settings instance, created on first use."""
    return Settings()
