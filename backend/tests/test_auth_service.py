from collections.abc import Callable, Iterator
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from argon2 import PasswordHasher
from pydantic import SecretStr
from sqlalchemy import event, func, select
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import Session

from app.database.session import get_engine, get_session_factory
from app.models import AuthSession, User
from app.repositories.auth_session_repository import AuthSessionRepository
from app.security import passwords
from app.security.password_policy import MAX_PASSWORD_LENGTH, MIN_PASSWORD_LENGTH
from app.security.session_tokens import hash_session_token
from app.services import auth_service as auth_service_module
from app.services.auth_errors import (
    AccountDisabledError,
    EmailAlreadyRegisteredError,
    InvalidCredentialsError,
    InvalidPasswordError,
    InvalidSessionError,
    RegistrationDisabledError,
)
from app.services.auth_service import AuthService, LoginResult

START = datetime(2030, 1, 1, 12, 0, tzinfo=UTC)
TTL = timedelta(days=7)
EMAIL = "marti@example.com"
PASSWORD = "correct horse battery staple"


class FakeClock:
    """Deterministic replacement for utc_now()."""

    def __init__(self, now: datetime) -> None:
        self.now = now

    def __call__(self) -> datetime:
        return self.now


@pytest.fixture
def clock() -> FakeClock:
    return FakeClock(START)


@pytest.fixture
def make_service(db_session: Session, clock: FakeClock) -> Callable[..., AuthService]:
    def factory(**overrides: Any) -> AuthService:
        options: dict[str, Any] = {
            "session_ttl": TTL,
            "registration_enabled": True,
            "clock": clock,
        }
        return AuthService(db_session, **(options | overrides))

    return factory


@pytest.fixture
def service(make_service: Callable[..., AuthService]) -> AuthService:
    return make_service()


@pytest.fixture
def tx(db_session: Session, monkeypatch: pytest.MonkeyPatch) -> list[str]:
    """Record commit()/rollback() calls while still performing them."""
    calls: list[str] = []
    real_commit, real_rollback = db_session.commit, db_session.rollback

    def commit() -> None:
        calls.append("commit")
        real_commit()

    def rollback() -> None:
        calls.append("rollback")
        real_rollback()

    monkeypatch.setattr(db_session, "commit", commit)
    monkeypatch.setattr(db_session, "rollback", rollback)
    return calls


@pytest.fixture
def sql_log(db_session: Session) -> Iterator[list[tuple[str, Any]]]:
    """Capture every SQL statement and its parameters sent to the database."""
    statements: list[tuple[str, Any]] = []

    def record(_conn: Any, _cursor: Any, statement: str, parameters: Any, *_: Any) -> None:
        statements.append((statement, parameters))

    engine = get_engine()
    event.listen(engine, "before_cursor_execute", record)
    yield statements
    event.remove(engine, "before_cursor_execute", record)


def _writes(statements: list[tuple[str, Any]]) -> list[str]:
    return [
        s for s, _ in statements if s.lstrip().upper().startswith(("INSERT", "UPDATE", "DELETE"))
    ]


def _count(db_session: Session, model: type) -> int:
    return db_session.scalar(select(func.count()).select_from(model))


def _sessions_of(db_session: Session, user: User) -> int:
    statement = select(func.count()).where(AuthSession.user_id == user.id)
    return db_session.scalar(statement)


def _spy(monkeypatch: pytest.MonkeyPatch, name: str) -> list[tuple[Any, ...]]:
    """Wrap a function imported into auth_service and record its calls."""
    calls: list[tuple[Any, ...]] = []
    real = getattr(auth_service_module, name)

    def wrapper(*args: Any) -> Any:
        calls.append(args)
        return real(*args)

    monkeypatch.setattr(auth_service_module, name, wrapper)
    return calls


# --- construction ---------------------------------------------------------------


@pytest.mark.parametrize("ttl", [timedelta(0), timedelta(seconds=-1), timedelta(days=-7)])
def test_service_rejects_non_positive_session_ttl(db_session: Session, ttl: timedelta) -> None:
    with pytest.raises(ValueError, match="session_ttl must be positive"):
        AuthService(db_session, session_ttl=ttl, registration_enabled=True)


# --- register --------------------------------------------------------------------


def test_register_creates_and_commits_user(service: AuthService, tx: list[str]) -> None:
    user = service.register("  Marti@Example.COM ", PASSWORD)

    assert user.email == EMAIL
    assert user.password_hash.startswith("$argon2id$")
    assert passwords.verify_password(user.password_hash, PASSWORD)
    assert tx == ["commit"]
    with get_session_factory()() as other_session:
        assert other_session.scalar(select(User.email)) == EMAIL


def test_register_never_creates_a_session(service: AuthService, db_session: Session) -> None:
    service.register(EMAIL, PASSWORD)

    assert _count(db_session, AuthSession) == 0


def test_register_duplicate_email_is_rejected_before_hashing(
    service: AuthService, db_session: Session, monkeypatch: pytest.MonkeyPatch
) -> None:
    service.register(EMAIL, PASSWORD)
    hash_calls = _spy(monkeypatch, "hash_password")

    with pytest.raises(EmailAlreadyRegisteredError):
        service.register(" MARTI@example.com", PASSWORD)

    assert hash_calls == []
    assert _count(db_session, User) == 1


def test_register_race_translates_integrity_error_after_rollback(
    service: AuthService, db_session: Session, tx: list[str], monkeypatch: pytest.MonkeyPatch
) -> None:
    service.register(EMAIL, PASSWORD)
    tx.clear()
    # Simulate a concurrent registration that passed the pre-check.
    monkeypatch.setattr(service._users, "get_by_email", lambda _email: None)

    with pytest.raises(EmailAlreadyRegisteredError) as exc_info:
        service.register(EMAIL, PASSWORD)

    assert tx == ["rollback"]
    assert exc_info.value.__cause__ is None
    assert exc_info.value.__suppress_context__ is True
    assert _count(db_session, User) == 1  # the session is still usable


def test_register_is_rejected_when_registration_is_disabled(
    make_service: Callable[..., AuthService], db_session: Session
) -> None:
    service = make_service(registration_enabled=False)

    with pytest.raises(RegistrationDisabledError):
        service.register(EMAIL, PASSWORD)

    assert _count(db_session, User) == 0


@pytest.mark.parametrize(
    "password",
    [
        "x" * MIN_PASSWORD_LENGTH,
        "x" * MAX_PASSWORD_LENGTH,
        "correct horse battery staple",  # spaces
        "contraseña muy segura 🔐 ñandú",  # Unicode
        " " * MIN_PASSWORD_LENGTH,  # length is the only rule
    ],
)
def test_register_accepts_passwords_within_policy(service: AuthService, password: str) -> None:
    user = service.register(EMAIL, password)

    assert passwords.verify_password(user.password_hash, password)


@pytest.mark.parametrize(
    "password", ["x" * (MIN_PASSWORD_LENGTH - 1), "x" * (MAX_PASSWORD_LENGTH + 1), ""]
)
def test_register_rejects_passwords_outside_policy_without_truncating(
    service: AuthService, db_session: Session, password: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    hash_calls = _spy(monkeypatch, "hash_password")

    with pytest.raises(InvalidPasswordError):
        service.register(EMAIL, password)

    assert hash_calls == []
    assert _count(db_session, User) == 0


def test_password_policy_bounds_are_15_and_128() -> None:
    assert (MIN_PASSWORD_LENGTH, MAX_PASSWORD_LENGTH) == (15, 128)


# --- login -----------------------------------------------------------------------


def test_login_creates_session_with_seven_day_expiry_in_one_commit(
    service: AuthService, db_session: Session, tx: list[str]
) -> None:
    user = service.register(EMAIL, PASSWORD)
    tx.clear()

    result = service.login(EMAIL, PASSWORD)

    assert tx == ["commit"]
    assert result.user is user
    assert len(result.session_token.get_secret_value()) == 43
    assert result.expires_at == START + timedelta(days=7)
    stored = db_session.scalars(select(AuthSession)).one()
    assert stored.token_hash == hash_session_token(result.session_token.get_secret_value())
    assert stored.expires_at == START + timedelta(days=7)


def test_login_matches_email_case_insensitively(service: AuthService) -> None:
    service.register(EMAIL, PASSWORD)

    assert service.login(" MARTI@Example.com", PASSWORD).user.email == EMAIL


def test_raw_token_never_reaches_the_database(
    service: AuthService, sql_log: list[tuple[str, Any]]
) -> None:
    service.register(EMAIL, PASSWORD)
    result = service.login(EMAIL, PASSWORD)
    raw_token = result.session_token.get_secret_value()
    service.authenticate(raw_token)
    service.logout(raw_token)

    all_parameters = repr([parameters for _, parameters in sql_log])
    assert raw_token not in all_parameters
    assert hash_session_token(raw_token) in all_parameters


def test_login_result_never_exposes_the_raw_token(service: AuthService) -> None:
    service.register(EMAIL, PASSWORD)
    result = service.login(EMAIL, PASSWORD)
    raw_token = result.session_token.get_secret_value()

    assert isinstance(result, LoginResult)
    assert isinstance(result.session_token, SecretStr)
    for rendered in (repr(result), str(result), str(result.session_token), f"{result}"):
        assert raw_token not in rendered


def test_unknown_email_performs_exactly_one_dummy_verification(
    service: AuthService, monkeypatch: pytest.MonkeyPatch
) -> None:
    dummy_calls = _spy(monkeypatch, "verify_dummy_password")
    real_calls = _spy(monkeypatch, "verify_password")

    with pytest.raises(InvalidCredentialsError):
        service.login("nobody@example.com", PASSWORD)

    assert dummy_calls == [(PASSWORD,)]
    assert real_calls == []


def test_wrong_password_gets_the_same_error_as_unknown_email(
    service: AuthService, monkeypatch: pytest.MonkeyPatch
) -> None:
    service.register(EMAIL, PASSWORD)
    dummy_calls = _spy(monkeypatch, "verify_dummy_password")

    with pytest.raises(InvalidCredentialsError) as wrong_password:
        service.login(EMAIL, PASSWORD + "!")
    with pytest.raises(InvalidCredentialsError) as unknown_email:
        service.login("nobody@example.com", PASSWORD)

    assert str(wrong_password.value) == str(unknown_email.value)
    assert len(dummy_calls) == 1  # only the unknown email used the dummy hash


@pytest.mark.parametrize("email", [EMAIL, "nobody@example.com"])
def test_failed_login_writes_nothing(
    service: AuthService,
    email: str,
    tx: list[str],
    sql_log: list[tuple[str, Any]],
) -> None:
    service.register(EMAIL, PASSWORD)
    tx.clear()
    sql_log.clear()

    with pytest.raises(InvalidCredentialsError):
        service.login(email, PASSWORD + "!")

    assert tx == []
    assert _writes(sql_log) == []


def test_inactive_account_is_rejected_only_after_correct_password(
    service: AuthService, db_session: Session, tx: list[str]
) -> None:
    user = service.register(EMAIL, PASSWORD)
    user.is_active = False
    db_session.commit()
    tx.clear()

    with pytest.raises(InvalidCredentialsError):
        service.login(EMAIL, PASSWORD + "!")
    with pytest.raises(AccountDisabledError):
        service.login(EMAIL, PASSWORD)

    assert tx == []
    assert _count(db_session, AuthSession) == 0


def test_login_rehashes_outdated_password_hash(service: AuthService, db_session: Session) -> None:
    old_hash = PasswordHasher(time_cost=2, memory_cost=19456, parallelism=1).hash(PASSWORD)
    db_session.add(User(email=EMAIL, password_hash=old_hash))
    db_session.commit()

    user = service.login(EMAIL, PASSWORD).user

    assert user.password_hash != old_hash
    assert passwords.password_needs_rehash(user.password_hash) is False
    assert passwords.verify_password(user.password_hash, PASSWORD)


def test_login_keeps_current_password_hash(service: AuthService) -> None:
    current_hash = service.register(EMAIL, PASSWORD).password_hash

    assert service.login(EMAIL, PASSWORD).user.password_hash == current_hash


def test_login_cleans_up_only_this_users_expired_sessions(
    service: AuthService, db_session: Session
) -> None:
    alice = service.register(EMAIL, PASSWORD)
    bob = service.register("bob@example.com", PASSWORD)
    repository = AuthSessionRepository(db_session)
    repository.create(alice.id, "a" * 64, START)  # expires exactly now: expired
    repository.create(alice.id, "b" * 64, START + timedelta(days=1))
    repository.create(bob.id, "c" * 64, START - timedelta(days=1))
    db_session.commit()

    result = service.login(EMAIL, PASSWORD)

    remaining = set(db_session.scalars(select(AuthSession.token_hash)))
    new_hash = hash_session_token(result.session_token.get_secret_value())
    assert remaining == {"b" * 64, "c" * 64, new_hash}


# --- authenticate ----------------------------------------------------------------


@pytest.fixture
def logged_in(service: AuthService) -> LoginResult:
    service.register(EMAIL, PASSWORD)
    return service.login(EMAIL, PASSWORD)


def test_authenticate_returns_user_without_writing(
    service: AuthService, logged_in: LoginResult, tx: list[str]
) -> None:
    user = service.authenticate(logged_in.session_token.get_secret_value())

    assert user is logged_in.user
    assert tx == []


@pytest.mark.parametrize("token", ["unknown-token", "", "x" * 43])
def test_authenticate_rejects_unknown_tokens(service: AuthService, token: str) -> None:
    with pytest.raises(InvalidSessionError):
        service.authenticate(token)


def test_session_is_valid_until_just_before_expiry(
    service: AuthService, logged_in: LoginResult, clock: FakeClock
) -> None:
    clock.now = logged_in.expires_at - timedelta(microseconds=1)

    assert service.authenticate(logged_in.session_token.get_secret_value()) is logged_in.user


def test_session_expiring_exactly_now_is_rejected_and_deleted(
    service: AuthService,
    logged_in: LoginResult,
    clock: FakeClock,
    db_session: Session,
    tx: list[str],
) -> None:
    clock.now = logged_in.expires_at

    with pytest.raises(InvalidSessionError):
        service.authenticate(logged_in.session_token.get_secret_value())

    assert tx == ["commit"]
    assert _count(db_session, AuthSession) == 0


def test_inactive_users_sessions_are_all_revoked_and_others_kept(
    service: AuthService, db_session: Session
) -> None:
    alice = service.register(EMAIL, PASSWORD)
    bob = service.register("bob@example.com", PASSWORD)
    alice_phone = service.login(EMAIL, PASSWORD)
    service.login(EMAIL, PASSWORD)  # alice's second device
    bob_session = service.login("bob@example.com", PASSWORD)
    alice.is_active = False
    db_session.commit()

    with pytest.raises(InvalidSessionError):
        service.authenticate(alice_phone.session_token.get_secret_value())

    assert _sessions_of(db_session, alice) == 0
    assert _sessions_of(db_session, bob) == 1
    assert service.authenticate(bob_session.session_token.get_secret_value()) is bob


# --- logout ----------------------------------------------------------------------


def test_logout_revokes_the_session(
    service: AuthService, logged_in: LoginResult, tx: list[str]
) -> None:
    raw_token = logged_in.session_token.get_secret_value()

    service.logout(raw_token)

    assert tx == ["commit"]
    with pytest.raises(InvalidSessionError):
        service.authenticate(raw_token)


def test_logout_is_idempotent(service: AuthService, logged_in: LoginResult) -> None:
    raw_token = logged_in.session_token.get_secret_value()

    service.logout(raw_token)
    service.logout(raw_token)
    service.logout("never-issued-token")


def test_logout_only_revokes_that_session(service: AuthService, logged_in: LoginResult) -> None:
    other_device = service.login(EMAIL, PASSWORD)

    service.logout(logged_in.session_token.get_secret_value())

    assert service.authenticate(other_device.session_token.get_secret_value()) is logged_in.user


# --- transactions ----------------------------------------------------------------


def test_failed_commit_rolls_back_the_whole_login(
    service: AuthService, db_session: Session, monkeypatch: pytest.MonkeyPatch
) -> None:
    service.register(EMAIL, PASSWORD)
    calls: list[str] = []
    real_rollback = db_session.rollback

    def failing_commit() -> None:
        calls.append("commit")
        raise OperationalError("COMMIT", {}, Exception("disk full"))

    def rollback() -> None:
        calls.append("rollback")
        real_rollback()

    monkeypatch.setattr(db_session, "commit", failing_commit)
    monkeypatch.setattr(db_session, "rollback", rollback)

    with pytest.raises(OperationalError):
        service.login(EMAIL, PASSWORD)

    assert calls == ["commit", "rollback"]
    assert _count(db_session, AuthSession) == 0
