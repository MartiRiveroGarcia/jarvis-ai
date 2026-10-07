import uuid

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.user import User, normalize_email


class UserRepository:
    """Persistence for users. Never commits: the service owns the transaction."""

    def __init__(self, session: Session) -> None:
        self._session = session

    def get_by_id(self, user_id: uuid.UUID) -> User | None:
        return self._session.get(User, user_id)

    def get_by_email(self, email: str) -> User | None:
        # @validates only normalises on assignment, so lookups normalise explicitly.
        statement = select(User).where(User.email == normalize_email(email))
        return self._session.scalars(statement).one_or_none()

    def create(self, email: str, password_hash: str) -> User:
        """Add a user; flushing surfaces a duplicate email as IntegrityError immediately."""
        user = User(email=email, password_hash=password_hash)
        self._session.add(user)
        self._session.flush()
        return user

    def update_password_hash(self, user: User, password_hash: str) -> None:
        user.password_hash = password_hash
