from collections.abc import Iterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from app import models  # noqa: F401  (registers all models on Base.metadata)
from app.config.settings import Settings, get_settings
from app.database.base import Base
from app.database.session import get_engine, get_session_factory
from app.dependencies import get_foundry_client
from app.main import create_app


def reset_database_caches() -> None:
    if get_engine.cache_info().currsize:
        get_engine().dispose()
    get_session_factory.cache_clear()
    get_engine.cache_clear()
    get_settings.cache_clear()
    get_foundry_client.cache_clear()


@pytest.fixture(autouse=True)
def ignore_local_foundry_configuration(monkeypatch: pytest.MonkeyPatch) -> None:
    """Never let a developer's backend/.env or shell configure the real Foundry.

    Without this, any test using the real dependencies could call Azure.
    """
    monkeypatch.setitem(Settings.model_config, "env_file", None)
    for name in (
        "JARVIS_FOUNDRY_PROJECT_ENDPOINT",
        "JARVIS_FOUNDRY_MODEL",
        "JARVIS_FOUNDRY_TIMEOUT_SECONDS",
        "JARVIS_FOUNDRY_MAX_OUTPUT_TOKENS",
    ):
        monkeypatch.delenv(name, raising=False)


@pytest.fixture(autouse=True)
def reset_cached_dependencies() -> Iterator[None]:
    """Give every test fresh settings, engine, session factory and Foundry client.

    Production code caches these once per process; without this reset, one test's
    database configuration could leak into the next.
    """
    reset_database_caches()
    yield
    reset_database_caches()


@pytest.fixture
def database_url(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> str:
    """Point DATABASE_URL at a temporary SQLite file for the duration of a test."""
    url = f"sqlite:///{tmp_path / 'test.db'}"
    monkeypatch.setenv("DATABASE_URL", url)
    reset_database_caches()
    return url


@pytest.fixture
def db_session(database_url: str) -> Iterator[Session]:
    """A session on a fresh temporary database with all tables created.

    Uses the application engine, so SQLite foreign keys are enforced. Tables are
    created from the models for speed; migrations are covered by test_migrations.
    """
    Base.metadata.create_all(get_engine())
    with get_session_factory()() as session:
        yield session


@pytest.fixture
def transaction_spy(db_session: Session, monkeypatch: pytest.MonkeyPatch) -> list[str]:
    """Record any commit()/rollback() on db_session; repositories must cause none."""
    calls: list[str] = []
    monkeypatch.setattr(db_session, "commit", lambda: calls.append("commit"))
    monkeypatch.setattr(db_session, "rollback", lambda: calls.append("rollback"))
    return calls


@pytest.fixture
def test_settings() -> Settings:
    # _env_file=None keeps a developer's local .env from leaking into tests.
    return Settings(_env_file=None, app_name="Jarvis API (test)", environment="test")


@pytest.fixture
def client(test_settings: Settings) -> Iterator[TestClient]:
    app = create_app()
    app.dependency_overrides[get_settings] = lambda: test_settings
    with TestClient(app) as test_client:
        yield test_client
