import uuid
from datetime import datetime

from sqlalchemy import delete, select
from sqlalchemy.orm import Session, joinedload

from app.models.auth_session import AuthSession


class AuthSessionRepository:
    """Persistence for login sessions, keyed by token hash only.

    Never commits, and makes no expiry decisions: both belong to the service.
    """

    def __init__(self, session: Session) -> None:
        self._session = session

    def create(self, user_id: uuid.UUID, token_hash: str, expires_at: datetime) -> AuthSession:
        auth_session = AuthSession(user_id=user_id, token_hash=token_hash, expires_at=expires_at)
        self._session.add(auth_session)
        self._session.flush()
        return auth_session

    def get_by_token_hash(self, token_hash: str) -> AuthSession | None:
        """Return the session (expired or not) with its user loaded in the same query."""
        statement = (
            select(AuthSession)
            .where(AuthSession.token_hash == token_hash)
            .options(joinedload(AuthSession.user))
        )
        return self._session.scalars(statement).one_or_none()

    def delete_by_token_hash(self, token_hash: str) -> bool:
        result = self._session.execute(
            delete(AuthSession).where(AuthSession.token_hash == token_hash)
        )
        return result.rowcount > 0

    def delete_all_for_user(self, user_id: uuid.UUID) -> int:
        result = self._session.execute(delete(AuthSession).where(AuthSession.user_id == user_id))
        return result.rowcount

    def delete_expired_for_user(self, user_id: uuid.UUID, now: datetime) -> int:
        """Delete the user's sessions with expires_at <= now; returns how many."""
        result = self._session.execute(
            delete(AuthSession).where(
                AuthSession.user_id == user_id,
                AuthSession.expires_at <= now,
            )
        )
        return result.rowcount
