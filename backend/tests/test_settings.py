from pathlib import Path

import pytest
from pydantic import ValidationError

from app.config.settings import BACKEND_DIR, Settings


@pytest.fixture(autouse=True)
def clear_settings_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in (
        "JARVIS_APP_NAME",
        "JARVIS_ENVIRONMENT",
        "DATABASE_URL",
        "JARVIS_DATABASE_URL",
    ):
        monkeypatch.delenv(name, raising=False)


def test_defaults_are_used_without_environment_variables() -> None:
    settings = Settings(_env_file=None)

    assert settings.app_name == "Jarvis API"
    assert settings.environment == "development"


def test_environment_variables_override_defaults(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("JARVIS_APP_NAME", "Jarvis Staging")
    monkeypatch.setenv("JARVIS_ENVIRONMENT", "production")

    settings = Settings(_env_file=None)

    assert settings.app_name == "Jarvis Staging"
    assert settings.environment == "production"


def test_values_are_read_from_env_file(tmp_path: Path) -> None:
    env_file = tmp_path / ".env"
    env_file.write_text("JARVIS_ENVIRONMENT=test\n")

    settings = Settings(_env_file=env_file)

    assert settings.environment == "test"


def test_invalid_environment_is_rejected(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("JARVIS_ENVIRONMENT", "staging")

    with pytest.raises(ValidationError):
        Settings(_env_file=None)


def test_database_url_defaults_to_sqlite_file_in_backend_dir() -> None:
    settings = Settings(_env_file=None)

    assert settings.database_url == f"sqlite:///{BACKEND_DIR / 'jarvis.db'}"


def test_database_url_is_read_from_unprefixed_env_var(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DATABASE_URL", "postgresql+psycopg://jarvis@db.example:5432/jarvis")

    settings = Settings(_env_file=None)

    assert settings.database_url == "postgresql+psycopg://jarvis@db.example:5432/jarvis"


def test_database_url_can_be_set_by_field_name() -> None:
    settings = Settings(_env_file=None, database_url="sqlite:///:memory:")

    assert settings.database_url == "sqlite:///:memory:"


def test_prefixed_database_url_env_var_is_ignored(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("JARVIS_DATABASE_URL", "sqlite:///should-be-ignored.db")

    settings = Settings(_env_file=None)

    assert settings.database_url == f"sqlite:///{BACKEND_DIR / 'jarvis.db'}"


def test_malformed_database_url_is_rejected_without_echoing_it(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("DATABASE_URL", "not a url with s3cret-password")

    with pytest.raises(ValidationError) as exc_info:
        Settings(_env_file=None)

    assert "s3cret-password" not in str(exc_info.value)


def test_database_url_is_excluded_from_repr() -> None:
    settings = Settings(
        _env_file=None,
        database_url="postgresql+psycopg://jarvis:s3cret-password@db.example/jarvis",
    )

    assert "s3cret-password" not in repr(settings)
