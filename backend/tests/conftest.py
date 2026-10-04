from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient

from app.config.settings import Settings, get_settings
from app.main import create_app


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
