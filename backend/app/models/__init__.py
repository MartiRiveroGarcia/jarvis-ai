"""SQLAlchemy ORM models.

Importing this package registers every model on Base.metadata, which Alembic and
SQLAlchemy's relationship resolution both rely on.
"""

from app.models.auth_session import AuthSession
from app.models.user import User

__all__ = ["AuthSession", "User"]
