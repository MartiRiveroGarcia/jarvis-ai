import uuid
from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import String, Uuid
from sqlalchemy.orm import Mapped, mapped_column, relationship, validates

from app.database.base import Base
from app.database.types import UTCDateTime, utc_now

if TYPE_CHECKING:
    from app.models.auth_session import AuthSession


# RFC 5321 practical limit; shared by the database column and the API schema.
EMAIL_MAX_LENGTH = 254


def normalize_email(email: str) -> str:
    """Canonical form used for storage, uniqueness and lookups."""
    return email.strip().lower()


class User(Base):
    __tablename__ = "users"

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    email: Mapped[str] = mapped_column(String(EMAIL_MAX_LENGTH), unique=True)
    password_hash: Mapped[str] = mapped_column(String(255))
    is_active: Mapped[bool] = mapped_column(default=True)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utc_now, onupdate=utc_now)

    # The database deletes sessions via ON DELETE CASCADE; passive_deletes avoids
    # loading them just to delete them.
    sessions: Mapped[list["AuthSession"]] = relationship(
        back_populates="user", cascade="all, delete-orphan", passive_deletes=True
    )

    @validates("email")
    def _normalize_email(self, _key: str, email: str) -> str:
        return normalize_email(email)
