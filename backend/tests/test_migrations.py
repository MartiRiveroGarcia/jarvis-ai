import ast
from datetime import timedelta
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import func, inspect, select

from app.config.settings import BACKEND_DIR
from app.database.session import get_engine, get_session_factory
from app.database.types import utc_now
from app.models import AuthSession, User

MIGRATIONS_DIR = BACKEND_DIR / "alembic" / "versions"


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


def _table_names() -> set[str]:
    return set(inspect(get_engine()).get_table_names()) - {"alembic_version"}


def test_upgrade_creates_auth_tables_with_expected_constraints(
    alembic_config: Config, database_url: str
) -> None:
    command.upgrade(alembic_config, "head")
    inspector = inspect(get_engine())

    assert _table_names() == {"users", "auth_sessions"}
    assert inspector.get_pk_constraint("users")["name"] == "pk_users"
    assert inspector.get_pk_constraint("auth_sessions")["name"] == "pk_auth_sessions"
    assert {c["name"] for c in inspector.get_unique_constraints("users")} == {"uq_users_email"}
    assert {c["name"] for c in inspector.get_unique_constraints("auth_sessions")} == {
        "uq_auth_sessions_token_hash"
    }
    assert {i["name"] for i in inspector.get_indexes("auth_sessions")} == {
        "ix_auth_sessions_expires_at",
        "ix_auth_sessions_user_id",
    }
    [foreign_key] = inspector.get_foreign_keys("auth_sessions")
    assert foreign_key["name"] == "fk_auth_sessions_user_id_users"
    assert foreign_key["referred_table"] == "users"
    assert foreign_key["options"]["ondelete"] == "CASCADE"


def test_migrated_schema_cascades_user_deletion_to_sessions(
    alembic_config: Config, database_url: str
) -> None:
    command.upgrade(alembic_config, "head")

    with get_session_factory()() as session:
        user = User(email="marti@example.com", password_hash="$argon2id$placeholder")
        session.add(
            AuthSession(user=user, token_hash="a" * 64, expires_at=utc_now() + timedelta(days=7))
        )
        session.commit()

        session.delete(user)
        session.commit()

        assert session.scalar(select(func.count()).select_from(AuthSession)) == 0


def test_downgrade_removes_tables_and_upgrade_restores_them(
    alembic_config: Config, database_url: str
) -> None:
    command.upgrade(alembic_config, "head")

    command.downgrade(alembic_config, "base")
    assert _table_names() == set()

    command.upgrade(alembic_config, "head")
    assert _table_names() == {"users", "auth_sessions"}


@pytest.mark.parametrize("migration", sorted(MIGRATIONS_DIR.glob("*.py")), ids=lambda p: p.name)
def test_migrations_do_not_import_application_code(migration: Path) -> None:
    # Migrations must keep working as application code evolves.
    imported = set()
    for node in ast.walk(ast.parse(migration.read_text())):
        if isinstance(node, ast.Import):
            imported.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            imported.add(node.module)

    assert not {name for name in imported if name == "app" or name.startswith("app.")}
    assert "app." not in migration.read_text()
