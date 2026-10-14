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
    for name in list(os.environ):
        if name.startswith("JARVIS_SPEECH_"):
            monkeypatch.delenv(name)
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
    # Foundry and Speech use Microsoft Entra ID; keys must never become configuration.
    names = {name.lower() for name in Settings.model_fields}

    assert not {name for name in names if "key" in name or "secret" in name}


# --- Azure AI Speech --------------------------------------------------------------

SPEECH_ENDPOINT = "https://jarvis-speech-test.cognitiveservices.azure.com"


def test_speech_is_optional_and_off_by_default() -> None:
    settings = _foundry()

    assert settings.speech_endpoint is None
    assert settings.speech_configured is False
    assert settings.speech_recognition_language == "ca-ES"
    assert settings.speech_voice == "ca-ES-AlbaNeural"
    assert settings.speech_stt_timeout_seconds == 45
    assert settings.speech_tts_timeout_seconds == 20


def test_speech_is_configured_from_the_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("JARVIS_SPEECH_ENDPOINT", SPEECH_ENDPOINT)
    monkeypatch.setenv("JARVIS_SPEECH_RECOGNITION_LANGUAGE", " es-ES ")
    monkeypatch.setenv("JARVIS_SPEECH_VOICE", " es-ES-ElviraNeural ")
    monkeypatch.setenv("JARVIS_SPEECH_STT_TIMEOUT_SECONDS", "30")
    monkeypatch.setenv("JARVIS_SPEECH_TTS_TIMEOUT_SECONDS", "10")

    settings = Settings(_env_file=None)

    assert settings.speech_configured is True
    assert settings.speech_endpoint == SPEECH_ENDPOINT
    assert settings.speech_recognition_language == "es-ES"
    assert settings.speech_voice == "es-ES-ElviraNeural"
    assert settings.speech_stt_timeout_seconds == 30
    assert settings.speech_tts_timeout_seconds == 10


def test_speech_does_not_depend_on_foundry() -> None:
    settings = _foundry(speech_endpoint=SPEECH_ENDPOINT)

    assert settings.speech_configured is True
    assert settings.foundry_configured is False


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        (SPEECH_ENDPOINT, SPEECH_ENDPOINT),
        (SPEECH_ENDPOINT + "/", SPEECH_ENDPOINT),
        (f"  {SPEECH_ENDPOINT}/  ", SPEECH_ENDPOINT),
        ("HTTPS://Jarvis-Speech-Test.CognitiveServices.Azure.com/", SPEECH_ENDPOINT),
        ("https://jarvis-speech-test.cognitiveservices.azure.com:443", SPEECH_ENDPOINT),
        ("https://a.cognitiveservices.azure.com", "https://a.cognitiveservices.azure.com"),
    ],
)
def test_valid_speech_endpoints_are_normalized(raw: str, expected: str) -> None:
    assert _foundry(speech_endpoint=raw).speech_endpoint == expected


@pytest.mark.parametrize(
    "raw",
    [
        "",
        "   ",
        "not a url",
        "http://jarvis-speech-test.cognitiveservices.azure.com",
        "jarvis-speech-test.cognitiveservices.azure.com",
        "ftp://jarvis-speech-test.cognitiveservices.azure.com",
        # Wrong hosts: regional endpoints, other Azure services, look-alikes.
        "https://swedencentral.api.cognitive.microsoft.com",
        "https://swedencentral.stt.speech.microsoft.com",
        "https://jarvis.openai.azure.com",
        "https://jarvis.services.ai.azure.com",
        "https://cognitiveservices.azure.com",
        "https://a.b.cognitiveservices.azure.com",
        "https://jarvis.cognitiveservices.azure.com.evil.example",
        "https://jarvis-.cognitiveservices.azure.com",
        "https://-jarvis.cognitiveservices.azure.com",
        "https://jar_vis.cognitiveservices.azure.com",
        # A Foundry project URL pasted by mistake.
        "https://res.services.ai.azure.com/api/projects/proj",
        # Paths, queries, fragments, credentials and ports.
        f"{SPEECH_ENDPOINT}/speechtotext",
        f"{SPEECH_ENDPOINT}/tts/cognitiveservices/v1",
        f"{SPEECH_ENDPOINT}//",
        f"{SPEECH_ENDPOINT}?api-version=1",
        f"{SPEECH_ENDPOINT}/?",
        f"{SPEECH_ENDPOINT}#section",
        f"{SPEECH_ENDPOINT}/#",
        "https://user:s3cret@jarvis-speech-test.cognitiveservices.azure.com",
        "https://user@jarvis-speech-test.cognitiveservices.azure.com",
        "https://jarvis-speech-test.cognitiveservices.azure.com:8443",
        "https://jarvis-speech-test.cognitiveservices.azure.com:notaport",
    ],
)
def test_invalid_speech_endpoints_are_rejected(raw: str) -> None:
    with pytest.raises(ValidationError) as exc_info:
        _foundry(speech_endpoint=raw)

    assert "JARVIS_SPEECH_ENDPOINT" in str(exc_info.value)


@pytest.mark.parametrize(
    "raw",
    [
        "https://user:s3cret@secret-speech.cognitiveservices.azure.com",
        "http://secret-speech.cognitiveservices.azure.com",
        "https://secret-speech.cognitiveservices.azure.com/secret-path",
        "https://secret-speech.cognitiveservices.azure.com?s3cret=1",
        "https://secret-speech.example.com",
    ],
)
def test_speech_endpoint_errors_never_echo_the_value(raw: str) -> None:
    with pytest.raises(ValidationError) as exc_info:
        _foundry(speech_endpoint=raw)

    message = str(exc_info.value)
    assert "secret-speech" not in message
    assert "s3cret" not in message
    assert "secret-path" not in message


def test_speech_endpoint_is_excluded_from_repr() -> None:
    settings = _foundry(speech_endpoint=SPEECH_ENDPOINT)

    assert "jarvis-speech-test" not in repr(settings)
    assert "jarvis-speech-test" not in str(settings)


@pytest.mark.parametrize("language", ["ca-ES", "en-US", "es-ES", "fil-PH", "zh-Hans-CN"])
def test_valid_recognition_languages_are_accepted(language: str) -> None:
    assert _foundry(speech_recognition_language=language).speech_recognition_language == language


@pytest.mark.parametrize(
    "language", ["", " ", "ca", "CA-ES", "ca-es", "ca_ES", "catalan", "ca-ES-x", "ca-ES;", "e-US"]
)
def test_invalid_recognition_languages_are_rejected(language: str) -> None:
    with pytest.raises(ValidationError) as exc_info:
        _foundry(speech_recognition_language=language)

    assert "JARVIS_SPEECH_RECOGNITION_LANGUAGE" in str(exc_info.value)


@pytest.mark.parametrize(
    "voice",
    [
        "ca-ES-EnricNeural",
        "ca-ES-AlbaNeural",
        "ca-ES-JoanaNeural",
        "en-US-AvaMultilingualNeural",
        "en-US-Ava:DragonHDLatestNeural",
        "zh-Hans-CN-XiaoxiaoNeural",
    ],
)
def test_valid_voices_are_accepted(voice: str) -> None:
    assert _foundry(speech_voice=voice).speech_voice == voice


@pytest.mark.parametrize(
    "voice",
    [
        "",
        "EnricNeural",
        "ca-ES",
        "ca-ES-",
        "ca-ES-Enric Neural",
        'ca-ES-Enric"Neural',
        "ca-ES-Enric'/><voice name='x",
        "ca-ES-Enric<Neural>",
        "ca-ES-Enric&Neural",
        "ca-ES-" + "a" * 65,
    ],
)
def test_invalid_voices_are_rejected(voice: str) -> None:
    with pytest.raises(ValidationError) as exc_info:
        _foundry(speech_voice=voice)

    assert "JARVIS_SPEECH_VOICE" in str(exc_info.value)


@pytest.mark.parametrize(
    ("field", "value", "valid"),
    [
        ("speech_stt_timeout_seconds", 0, False),
        ("speech_stt_timeout_seconds", 1, True),
        ("speech_stt_timeout_seconds", 120, True),
        ("speech_stt_timeout_seconds", 121, False),
        ("speech_tts_timeout_seconds", 0, False),
        ("speech_tts_timeout_seconds", 1, True),
        ("speech_tts_timeout_seconds", 120, True),
        ("speech_tts_timeout_seconds", 121, False),
    ],
)
def test_speech_timeout_bounds(field: str, value: int, valid: bool) -> None:
    if valid:
        assert getattr(_foundry(**{field: value}), field) == value
    else:
        with pytest.raises(ValidationError):
            _foundry(**{field: value})


def test_there_are_no_speech_key_region_or_identity_settings() -> None:
    names = {name for name in Settings.model_fields if name.startswith("speech_")}

    assert names == {
        "speech_endpoint",
        "speech_recognition_language",
        "speech_voice",
        "speech_stt_timeout_seconds",
        "speech_tts_timeout_seconds",
    }
    for forbidden in ("key", "secret", "region", "tenant", "subscription", "client"):
        assert not [name for name in Settings.model_fields if forbidden in name], forbidden


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
assert get_settings().speech_configured is (sys.argv[2] == "configured")
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
# The native Speech SDK is never loaded at startup or by other endpoints.
assert not [m for m in sys.modules if m.startswith("azure.cognitiveservices")]
assert get_foundry_client.cache_info().currsize == 0
"""


@pytest.mark.parametrize("speech", ["configured", "not-configured"])
@pytest.mark.parametrize("foundry", ["configured", "not-configured"])
def test_startup_and_other_endpoints_never_touch_azure(
    tmp_path: Path, foundry: str, speech: str
) -> None:
    # SDK modules may be imported (except the native Speech SDK); what must not
    # happen is creating an Azure credential, requesting a token or any network call.
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("JARVIS_FOUNDRY_", "JARVIS_SPEECH_"))
    }
    env["DATABASE_URL"] = f"sqlite:///{tmp_path / 'startup.db'}"
    if foundry == "configured":
        env["JARVIS_FOUNDRY_PROJECT_ENDPOINT"] = ENDPOINT
        env["JARVIS_FOUNDRY_MODEL"] = "startup-test-deployment"
    if speech == "configured":
        env["JARVIS_SPEECH_ENDPOINT"] = SPEECH_ENDPOINT

    subprocess.run(
        [sys.executable, "-c", _STARTUP_SCRIPT, foundry, speech],
        cwd=BACKEND_DIR,
        env=env,
        check=True,
    )
