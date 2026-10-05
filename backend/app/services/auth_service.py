from collections.abc import Callable, Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta

from pydantic import SecretStr
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.database.types import utc_now
from app.models.user import User
from app.repositories.auth_session_repository import AuthSessionRepository
from app.repositories.user_repository import UserRepository
from app.security.password_policy import password_meets_policy
from app.security.passwords import (
    hash_password,
    password_needs_rehash,
    verify_dummy_password,
    verify_password,
)
from app.security.session_tokens import (
    generate_session_token,
    hash_session_token,
    is_well_formed_session_token,
)
from app.services.auth_errors import (
    AccountDisabledError,
    EmailAlreadyRegisteredError,
    InvalidCredentialsError,
    InvalidPasswordError,
    InvalidSessionError,
    RegistrationDisabledError,
)

Clock = Callable[[], datetime]


@dataclass(frozen=True, slots=True)
class LoginResult:
    """Outcome of a successful login.

    session_token is the raw token for the HttpOnly cookie. It is a SecretStr so it
    is masked in repr, str and logs; it is never persisted.
    """

    user: User
    session_token: SecretStr
    expires_at: datetime


class AuthService:
    """Authentication use cases. Owns every commit and rollback; repositories never do."""

    def __init__(
        self,
        session: Session,
        *,
        session_ttl: timedelta,
        registration_enabled: bool,
        clock: Clock = utc_now,
    ) -> None:
        if session_ttl <= timedelta(0):
            raise ValueError("session_ttl must be positive")
        self._session = session
        self._users = UserRepository(session)
        self._sessions = AuthSessionRepository(session)
        self._session_ttl = session_ttl
        self._registration_enabled = registration_enabled
        self._clock = clock

    def register(self, email: str, password: str) -> User:
        """Create an account. Does not log the user in."""
        if not self._registration_enabled:
            raise RegistrationDisabledError
        if not password_meets_policy(password):
            raise InvalidPasswordError
        if self._users.get_by_email(email) is not None:
            raise EmailAlreadyRegisteredError

        password_hash = hash_password(password)
        try:
            with self._transaction():
                user = self._users.create(email, password_hash)
        except IntegrityError:
            # A concurrent registration won the race; the unique email constraint is
            # the real guarantee. The transaction is already rolled back. "from None"
            # keeps the failed INSERT out of logged tracebacks.
            raise EmailAlreadyRegisteredError from None
        return user

    def login(self, email: str, password: str) -> LoginResult:
        """Verify credentials and start a new session in a single transaction."""
        now = self._clock()
        user = self._users.get_by_email(email)
        if user is None:
            # Same Argon2 cost as a wrong password, so timing does not reveal accounts.
            verify_dummy_password(password)
            raise InvalidCredentialsError
        if not verify_password(user.password_hash, password):
            raise InvalidCredentialsError
        # Checked only after a correct password, so it reveals nothing to guessers.
        if not user.is_active:
            raise AccountDisabledError

        raw_token = generate_session_token()
        with self._transaction():
            if password_needs_rehash(user.password_hash):
                self._users.update_password_hash(user, hash_password(password))
            self._sessions.delete_expired_for_user(user.id, now)
            auth_session = self._sessions.create(
                user.id, hash_session_token(raw_token), now + self._session_ttl
            )
        return LoginResult(
            user=user, session_token=SecretStr(raw_token), expires_at=auth_session.expires_at
        )

    def authenticate(self, raw_token: str) -> User:
        """Return the user owning a valid session, revoking expired or disabled ones."""
        if not is_well_formed_session_token(raw_token):
            raise InvalidSessionError  # rejected without any database work
        now = self._clock()
        auth_session = self._sessions.get_by_token_hash(hash_session_token(raw_token))
        if auth_session is None:
            raise InvalidSessionError
        if auth_session.expires_at <= now:
            with self._transaction():
                self._sessions.delete_by_token_hash(auth_session.token_hash)
            raise InvalidSessionError
        if not auth_session.user.is_active:
            # A disabled account should be logged out everywhere, not just here.
            with self._transaction():
                self._sessions.delete_all_for_user(auth_session.user_id)
            raise InvalidSessionError
        return auth_session.user

    def logout(self, raw_token: str) -> None:
        """Revoke the session for this token. Idempotent: unknown tokens are fine."""
        if not is_well_formed_session_token(raw_token):
            return  # cannot be one of our sessions; nothing to revoke
        with self._transaction():
            self._sessions.delete_by_token_hash(hash_session_token(raw_token))

    @contextmanager
    def _transaction(self) -> Iterator[None]:
        """Commit on success, roll back on any error. The only commit/rollback site."""
        try:
            yield
            self._session.commit()
        except Exception:
            self._session.rollback()
            raise
