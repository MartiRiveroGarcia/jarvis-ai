from collections.abc import Iterator
from functools import lru_cache
from sqlite3 import Connection as SQLiteConnection
from typing import Any

from sqlalchemy import Engine, create_engine, event
from sqlalchemy.orm import Session, sessionmaker

from app.config.settings import get_settings


def create_db_engine(database_url: str) -> Engine:
    """Create an engine for application use.

    Creating an engine does not open a connection; that happens on first use.
    """
    # hide_parameters keeps bound values (e.g. password or token hashes) out of
    # SQLAlchemy error messages and logs.
    engine = create_engine(database_url, hide_parameters=True)
    if engine.dialect.name == "sqlite":
        event.listen(engine, "connect", _enable_sqlite_foreign_keys)
    return engine


def _enable_sqlite_foreign_keys(dbapi_connection: SQLiteConnection, _record: Any) -> None:
    # SQLite ignores foreign keys unless enabled on every new connection.
    cursor = dbapi_connection.cursor()
    cursor.execute("PRAGMA foreign_keys=ON")
    cursor.close()


@lru_cache
def get_engine() -> Engine:
    """Return the process-wide engine, created lazily on first use."""
    return create_db_engine(get_settings().database_url)


@lru_cache
def get_session_factory() -> sessionmaker[Session]:
    """Return the process-wide session factory bound to the shared engine."""
    return sessionmaker(bind=get_engine(), autoflush=False, expire_on_commit=False)


def get_db() -> Iterator[Session]:
    """Provide one session per request; it is closed when the request ends.

    The session never commits on its own: services commit explicitly, and any
    uncommitted changes are discarded when the session closes.
    """
    with get_session_factory()() as session:
        yield session
