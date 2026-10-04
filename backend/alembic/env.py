"""Alembic migration environment for the Jarvis backend."""

from logging.config import fileConfig

from alembic import context
from sqlalchemy import Connection, create_engine
from sqlalchemy.pool import NullPool

from app.config.settings import get_settings
from app.database.base import Base

config = context.config

if config.config_file_name is not None:
    # Keep loggers configured by the caller (e.g. pytest) working.
    fileConfig(config.config_file_name, disable_existing_loggers=False)

target_metadata = Base.metadata


def get_database_url() -> str:
    # Programmatic callers (tests) may pass a URL via config.attributes; it cannot
    # come from alembic.ini, so the ini file can never override DATABASE_URL.
    return config.attributes.get("database_url") or get_settings().database_url


def configure_context(connection: Connection) -> None:
    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        # SQLite cannot ALTER most table properties; batch mode recreates the table.
        render_as_batch=connection.dialect.name == "sqlite",
    )


def run_migrations_offline() -> None:
    """Emit SQL to stdout instead of executing it (`alembic upgrade --sql`)."""
    url = get_database_url()
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        render_as_batch=url.startswith("sqlite"),
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    # A plain engine on purpose: unlike the application engine, migrations run
    # with SQLite foreign keys OFF, as recommended for batch table recreation.
    engine = create_engine(get_database_url(), poolclass=NullPool)
    with engine.connect() as connection:
        configure_context(connection)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
