import os
import subprocess
import sys
from pathlib import Path

import pytest
from sqlalchemy import Column, ForeignKey, Integer, MetaData, String, Table, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.schema import CreateTable

from app.config.settings import BACKEND_DIR
from app.database.base import NAMING_CONVENTION, Base
from app.database.session import create_db_engine, get_db, get_engine, get_session_factory
from tests.conftest import reset_database_caches


def test_base_metadata_uses_naming_convention() -> None:
    assert Base.metadata.naming_convention == NAMING_CONVENTION


def test_naming_convention_produces_deterministic_constraint_names() -> None:
    # A separate MetaData keeps throwaway tables out of Base.metadata (Alembic's target).
    metadata = MetaData(naming_convention=NAMING_CONVENTION)
    parent = Table("parent", metadata, Column("id", Integer, primary_key=True))
    child = Table(
        "child",
        metadata,
        Column("id", Integer, primary_key=True),
        Column("code", String(10), unique=True),
        Column("parent_id", ForeignKey("parent.id")),
    )
    engine = create_db_engine("sqlite://")

    ddl = str(CreateTable(child).compile(engine)) + str(CreateTable(parent).compile(engine))

    assert "CONSTRAINT pk_child PRIMARY KEY" in ddl
    assert "CONSTRAINT uq_child_code UNIQUE" in ddl
    assert "CONSTRAINT fk_child_parent_id_parent FOREIGN KEY" in ddl
    assert "CONSTRAINT pk_parent PRIMARY KEY" in ddl


def test_creating_engine_does_not_create_database_file(tmp_path: Path) -> None:
    db_file = tmp_path / "lazy.db"

    create_db_engine(f"sqlite:///{db_file}")

    assert not db_file.exists()


def test_sqlite_connections_enable_foreign_keys(tmp_path: Path) -> None:
    engine = create_db_engine(f"sqlite:///{tmp_path / 'fk.db'}")

    with engine.connect() as connection:
        assert connection.exec_driver_sql("PRAGMA foreign_keys").scalar() == 1


def test_sqlite_rejects_rows_violating_foreign_keys(tmp_path: Path) -> None:
    engine = create_db_engine(f"sqlite:///{tmp_path / 'fk.db'}")
    with engine.begin() as connection:
        connection.exec_driver_sql("CREATE TABLE parent (id INTEGER PRIMARY KEY)")
        connection.exec_driver_sql(
            "CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent(id))"
        )

    with pytest.raises(IntegrityError), engine.begin() as connection:
        connection.exec_driver_sql("INSERT INTO child (id, parent_id) VALUES (1, 999)")


def test_engine_and_session_factory_are_cached_and_use_database_url(database_url: str) -> None:
    engine = get_engine()

    assert get_engine() is engine
    assert get_session_factory() is get_session_factory()
    assert get_session_factory().kw["bind"] is engine
    assert engine.url.render_as_string(hide_password=False) == database_url


def test_cache_reset_rebuilds_engine_for_new_database_url(
    database_url: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    previous_engine = get_engine()
    previous_factory = get_session_factory()
    other_url = f"sqlite:///{tmp_path / 'other.db'}"
    monkeypatch.setenv("DATABASE_URL", other_url)

    reset_database_caches()

    assert get_engine() is not previous_engine
    assert get_session_factory() is not previous_factory
    assert get_engine().url.render_as_string(hide_password=False) == other_url


def test_get_db_yields_working_session_and_releases_connection(database_url: str) -> None:
    dependency = get_db()
    session = next(dependency)

    assert session.execute(text("SELECT 1")).scalar() == 1
    assert get_engine().pool.checkedout() == 1

    dependency.close()

    assert not session.in_transaction()
    assert get_engine().pool.checkedout() == 0


def test_get_db_discards_uncommitted_changes(database_url: str) -> None:
    with get_engine().begin() as connection:
        connection.exec_driver_sql("CREATE TABLE notes (id INTEGER PRIMARY KEY)")

    dependency = get_db()
    session = next(dependency)
    session.execute(text("INSERT INTO notes (id) VALUES (1)"))
    dependency.close()

    with get_session_factory()() as session:
        assert session.execute(text("SELECT COUNT(*) FROM notes")).scalar() == 0


def test_importing_and_serving_the_app_does_not_touch_the_database(tmp_path: Path) -> None:
    # A fresh interpreter, so module imports run for real instead of being cached.
    db_file = tmp_path / "untouched.db"
    script = (
        "from fastapi.testclient import TestClient\n"
        "from app.config.settings import get_settings\n"
        "from app.main import app\n"
        "get_settings()\n"
        "assert TestClient(app).get('/api/health').status_code == 200\n"
    )
    env = {**os.environ, "DATABASE_URL": f"sqlite:///{db_file}"}

    subprocess.run([sys.executable, "-c", script], cwd=BACKEND_DIR, env=env, check=True)

    assert not db_file.exists()
