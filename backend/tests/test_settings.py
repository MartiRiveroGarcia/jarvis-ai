from pathlib import Path

import pytest
from pydantic import ValidationError

from app.config.settings import Settings


@pytest.fixture(autouse=True)
def clear_jarvis_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in ("JARVIS_APP_NAME", "JARVIS_ENVIRONMENT"):
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
