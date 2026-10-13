import os
import subprocess
import sys
from datetime import timedelta
from pathlib import Path

import pytest
from pydantic import ValidationError

from app.config.settings import BACKEND_DIR, Settings


@pytest.fixture(autouse=True)
def clear_settings_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in (
        "JARVIS_APP_NAME",
        "JARVIS_ENVIRONMENT",
        "JARVIS_SESSION_TTL_DAYS",
        "JARVIS_REGISTRATION_ENABLED",
        "DATABASE_URL",
        "JARVIS_DATABASE_URL",
        "JARVIS_FOUNDRY_PROJECT_ENDPOINT",
        "JARVIS_FOUNDRY_MODEL",
        "JARVIS_FOUNDRY_TIMEOUT_SECONDS",
        "JARVIS_FOUNDRY_MAX_OUTPUT_TOKENS",
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


def test_session_ttl_defaults_to_seven_days() -> None:
    settings = Settings(_env_file=None)

    assert settings.session_ttl_days == 7
    assert settings.session_ttl == timedelta(days=7)


def test_session_ttl_can_be_overridden(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("JARVIS_SESSION_TTL_DAYS", "30")

    assert Settings(_env_file=None).session_ttl == timedelta(days=30)


@pytest.mark.parametrize("days", ["0", "-1", "91", "seven"])
def test_invalid_session_ttl_is_rejected(monkeypatch: pytest.MonkeyPatch, days: str) -> None:
    monkeypatch.setenv("JARVIS_SESSION_TTL_DAYS", days)

    with pytest.raises(ValidationError):
        Settings(_env_file=None)


def test_registration_is_enabled_by_default() -> None:
    assert Settings(_env_file=None).registration_enabled is True


@pytest.mark.parametrize("value", ["false", "0", "False"])
def test_registration_can_be_disabled(monkeypatch: pytest.MonkeyPatch, value: str) -> None:
    monkeypatch.setenv("JARVIS_REGISTRATION_ENABLED", value)

    assert Settings(_env_file=None).registration_enabled is False


# --- Microsoft Foundry ------------------------------------------------------------

ENDPOINT = "https://res.services.ai.azure.com/api/projects/proj"


def _foundry(**values: object) -> Settings:
    return Settings(_env_file=None, **values)


def test_foundry_is_optional_and_off_by_default() -> None:
    settings = _foundry()

    assert settings.foundry_project_endpoint is None
    assert settings.foundry_model is None
    assert settings.foundry_configured is False
    assert settings.foundry_timeout_seconds == 25
    assert settings.foundry_max_output_tokens == 2000


def test_foundry_is_configured_when_endpoint_and_model_are_set(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("JARVIS_FOUNDRY_PROJECT_ENDPOINT", ENDPOINT)
    monkeypatch.setenv("JARVIS_FOUNDRY_MODEL", " gpt-5-mini ")

    settings = Settings(_env_file=None)

    assert settings.foundry_configured is True
    assert settings.foundry_project_endpoint == ENDPOINT
    assert settings.foundry_model == "gpt-5-mini"


@pytest.mark.parametrize(
    "values",
    [{"foundry_project_endpoint": ENDPOINT}, {"foundry_model": "my-deployment"}],
    ids=["endpoint-only", "model-only"],
)
def test_partial_foundry_configuration_is_rejected(values: dict[str, str]) -> None:
    with pytest.raises(ValidationError, match="must be set together"):
        _foundry(**values)


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        (ENDPOINT, ENDPOINT),
        (ENDPOINT + "/", ENDPOINT),
        ("  " + ENDPOINT + "  ", ENDPOINT),
        (
            "HTTPS://RES.Services.AI.Azure.com/api/projects/MyProject",
            "https://res.services.ai.azure.com/api/projects/MyProject",
        ),
        (
            "https://res.services.ai.azure.com:443/api/projects/p.1_x-y~",
            "https://res.services.ai.azure.com:443/api/projects/p.1_x-y~",
        ),
    ],
)
def test_valid_project_endpoints_are_normalized(raw: str, expected: str) -> None:
    assert (
        _foundry(foundry_project_endpoint=raw, foundry_model="m").foundry_project_endpoint
        == expected
    )


@pytest.mark.parametrize(
    "raw",
    [
        "",
        "   ",
        "http://res.services.ai.azure.com/api/projects/proj",
        "res.services.ai.azure.com/api/projects/proj",
        "/api/projects/proj",
        "https:///api/projects/proj",
        "https://user:s3cret@res.services.ai.azure.com/api/projects/proj",
        "https://res.services.ai.azure.com/api/projects/proj?api-version=1",
        "https://res.services.ai.azure.com/api/projects/proj?",
        "https://res.services.ai.azure.com/api/projects/proj#section",
        "https://res.services.ai.azure.com/api/projects",
        "https://res.services.ai.azure.com/api/projects/",
        "https://res.services.ai.azure.com/api/projects/proj/openai/v1",
        "https://res.services.ai.azure.com/projects/proj",
        "https://res.openai.azure.com/openai/v1",
        "https://res.services.ai.azure.com/api/projects/..",
        "https://res.services.ai.azure.com/api/projects/a%2Fb",
        "https://res.services.ai.azure.com:notaport/api/projects/proj",
    ],
)
def test_invalid_project_endpoints_are_rejected(raw: str) -> None:
    with pytest.raises(ValidationError):
        _foundry(foundry_project_endpoint=raw, foundry_model="m")


@pytest.mark.parametrize("model", ["", "   ", "a" * 65, "my deployment", "deploy/ment", "deploy?x"])
def test_invalid_deployment_names_are_rejected(model: str) -> None:
    with pytest.raises(ValidationError, match="JARVIS_FOUNDRY_MODEL"):
        _foundry(foundry_project_endpoint=ENDPOINT, foundry_model=model)


@pytest.mark.parametrize("model", ["gpt-5-mini", "my_deployment.v2", "a" * 64])
def test_valid_deployment_names_are_accepted(model: str) -> None:
    assert _foundry(foundry_project_endpoint=ENDPOINT, foundry_model=model).foundry_model == model


@pytest.mark.parametrize(
    ("field", "value", "valid"),
    [
        ("foundry_timeout_seconds", 0, False),
        ("foundry_timeout_seconds", 1, True),
        ("foundry_timeout_seconds", 120, True),
        ("foundry_timeout_seconds", 121, False),
        ("foundry_max_output_tokens", 15, False),
        ("foundry_max_output_tokens", 16, True),
        ("foundry_max_output_tokens", 16384, True),
        ("foundry_max_output_tokens", 16385, False),
    ],
)
def test_foundry_numeric_bounds(field: str, value: int, valid: bool) -> None:
    if valid:
        assert getattr(_foundry(**{field: value}), field) == value
    else:
        with pytest.raises(ValidationError):
            _foundry(**{field: value})


@pytest.mark.parametrize(
    "raw",
    [
        "https://user:s3cret@secret-host.services.ai.azure.com/api/projects/proj",
        "http://secret-host.services.ai.azure.com/api/projects/proj",
        "https://secret-host.services.ai.azure.com/api/projects/proj?s3cret=1",
        "https://secret-host.services.ai.azure.com/wrong/path",
    ],
)
def test_endpoint_errors_never_echo_the_value(raw: str) -> None:
    with pytest.raises(ValidationError) as exc_info:
        _foundry(foundry_project_endpoint=raw, foundry_model="m")

    message = str(exc_info.value)
    assert "secret-host" not in message
    assert "s3cret" not in message
    assert "JARVIS_FOUNDRY_PROJECT_ENDPOINT" in message


def test_endpoint_is_excluded_from_repr() -> None:
    settings = _foundry(foundry_project_endpoint=ENDPOINT, foundry_model="m")

    assert "res.services.ai.azure.com" not in repr(settings)


def test_there_is_no_api_key_setting() -> None:
    # Foundry access uses Microsoft Entra ID; keys must never become configuration.
    names = {name.lower() for name in Settings.model_fields}

    assert not {name for name in names if "key" in name or "secret" in name}


# Runs in a fresh interpreter. Every way to reach Azure is replaced with a recorder
# *before* the app is imported: the Entra ID credential and token provider, the
# Foundry SDK client and any outbound socket. The app then starts and serves health
# and the full auth flow; nothing may have been recorded.
_STARTUP_SCRIPT = """
import socket
import sys

import azure.identity

used = []


class RecordingCredential:
    def __init__(self, *args, **kwargs):
        used.append("DefaultAzureCredential")

    def get_token(self, *args, **kwargs):
        used.append("get_token")


def recording_token_provider(*args, **kwargs):
    used.append("get_bearer_token_provider")


azure.identity.DefaultAzureCredential = RecordingCredential
azure.identity.get_bearer_token_provider = recording_token_provider

from app.integrations.foundry import responses_client


def recording_get_client(self):
    used.append("foundry_sdk_client")


responses_client.FoundryResponsesClient._get_client = recording_get_client

original_connect = socket.socket.connect


def recording_connect(self, address):
    used.append("socket_connect")
    return original_connect(self, address)


socket.socket.connect = recording_connect

from fastapi.testclient import TestClient

from app import models  # noqa: F401
from app.config.settings import Settings, get_settings
from app.database.base import Base
from app.database.session import get_engine

# Ignore a developer's local .env, which may configure the real Foundry.
Settings.model_config["env_file"] = None

from app.dependencies import get_foundry_client
from app.main import app

assert get_settings().foundry_configured is (sys.argv[1] == "configured")
Base.metadata.create_all(get_engine())

with TestClient(app) as client:
    assert client.get("/api/health").status_code == 200
    account = {"email": "startup@example.com", "password": "correct horse battery staple"}
    assert client.post("/api/auth/register", json=account).status_code == 201
    token = client.post("/api/auth/login", json=account).json()["session_token"]
    headers = {"Authorization": f"Bearer {token}"}
    assert client.get("/api/auth/me", headers=headers).status_code == 200
    assert client.post("/api/auth/logout", headers=headers).status_code == 204

assert used == [], used
assert get_foundry_client.cache_info().currsize == 0
"""


@pytest.mark.parametrize("foundry", ["configured", "not-configured"])
def test_startup_and_other_endpoints_never_touch_azure(tmp_path: Path, foundry: str) -> None:
    # SDK modules may be imported; what must not happen is creating an Azure
    # credential, requesting a token or calling Foundry over the network.
    env = {key: value for key, value in os.environ.items() if not key.startswith("JARVIS_FOUNDRY_")}
    env["DATABASE_URL"] = f"sqlite:///{tmp_path / 'startup.db'}"
    if foundry == "configured":
        env["JARVIS_FOUNDRY_PROJECT_ENDPOINT"] = ENDPOINT
        env["JARVIS_FOUNDRY_MODEL"] = "startup-test-deployment"

    subprocess.run(
        [sys.executable, "-c", _STARTUP_SCRIPT, foundry], cwd=BACKEND_DIR, env=env, check=True
    )
