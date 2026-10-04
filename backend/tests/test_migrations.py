from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config

from app.config.settings import BACKEND_DIR


@pytest.fixture
def alembic_config() -> Config:
    return Config(BACKEND_DIR / "alembic.ini")


def _sqlite_file(database_url: str) -> Path:
    return Path(database_url.removeprefix("sqlite:///"))


def test_upgrade_head_runs_against_database_url(alembic_config: Config, database_url: str) -> None:
    command.upgrade(alembic_config, "head")

    assert _sqlite_file(database_url).exists()


def test_models_and_migrations_are_in_sync(alembic_config: Config, database_url: str) -> None:
    command.upgrade(alembic_config, "head")

    # Raises if autogenerate would produce a new migration.
    command.check(alembic_config)


def test_programmatic_url_takes_precedence_over_database_url(
    alembic_config: Config, database_url: str, tmp_path: Path
) -> None:
    override_file = tmp_path / "override.db"
    alembic_config.attributes["database_url"] = f"sqlite:///{override_file}"

    command.upgrade(alembic_config, "head")

    assert override_file.exists()
    assert not _sqlite_file(database_url).exists()
