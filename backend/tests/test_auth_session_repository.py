from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import inspect, select
from sqlalchemy.orm import Session

from app.database.types import utc_now
from app.models import AuthSession, User
from app.repositories.auth_session_repository import AuthSessionRepository

NOW = utc_now()
FUTURE = NOW + timedelta(days=7)
PAST = NOW - timedelta(seconds=1)


@pytest.fixture
def sessions(db_session: Session) -> AuthSessionRepository:
    return AuthSessionRepository(db_session)


@pytest.fixture
def alice(db_session: Session) -> User:
    return _add_user(db_session, "alice@example.com")


@pytest.fixture
def bob(db_session: Session) -> User:
    return _add_user(db_session, "bob@example.com")


def _add_user(db_session: Session, email: str) -> User:
    user = User(email=email, password_hash="$argon2id$placeholder")
    db_session.add(user)
    db_session.flush()
    return user


def _hash(label: str) -> str:
    return label.ljust(64, "0")


def _remaining_hashes(db_session: Session) -> set[str]:
    return set(db_session.scalars(select(AuthSession.token_hash)))


def test_create_stores_given_values(sessions: AuthSessionRepository, alice: User) -> None:
    auth_session = sessions.create(alice.id, _hash("a"), FUTURE)

    assert auth_session.user_id == alice.id
    assert auth_session.token_hash == _hash("a")
    assert auth_session.expires_at == FUTURE
    assert auth_session.created_at is not None


def test_create_does_not_commit(
    sessions: AuthSessionRepository, alice: User, db_session: Session
) -> None:
    session_id = sessions.create(alice.id, _hash("a"), FUTURE).id

    db_session.rollback()

    assert db_session.get(AuthSession, session_id) is None


def test_get_by_token_hash_eagerly_loads_user(
    sessions: AuthSessionRepository, alice: User, db_session: Session
) -> None:
    sessions.create(alice.id, _hash("a"), FUTURE)
    db_session.commit()
    db_session.expunge_all()  # force a real query instead of the identity map

    found = sessions.get_by_token_hash(_hash("a"))

    assert found is not None
    assert "user" not in inspect(found).unloaded
    assert found.user.email == "alice@example.com"


def test_get_by_token_hash_returns_none_for_unknown_hash(sessions: AuthSessionRepository) -> None:
    assert sessions.get_by_token_hash(_hash("unknown")) is None


def test_get_by_token_hash_returns_expired_sessions(
    sessions: AuthSessionRepository, alice: User
) -> None:
    sessions.create(alice.id, _hash("expired"), PAST)

    found = sessions.get_by_token_hash(_hash("expired"))

    assert found is not None
    assert found.expires_at == PAST


def test_delete_by_token_hash_is_idempotent(
    sessions: AuthSessionRepository, alice: User, db_session: Session
) -> None:
    sessions.create(alice.id, _hash("a"), FUTURE)
    sessions.create(alice.id, _hash("b"), FUTURE)

    assert sessions.delete_by_token_hash(_hash("a")) is True
    assert sessions.delete_by_token_hash(_hash("a")) is False
    assert _remaining_hashes(db_session) == {_hash("b")}


def test_delete_all_for_user_never_affects_other_users(
    sessions: AuthSessionRepository, alice: User, bob: User, db_session: Session
) -> None:
    sessions.create(alice.id, _hash("alice-1"), FUTURE)
    sessions.create(alice.id, _hash("alice-2"), PAST)
    sessions.create(bob.id, _hash("bob-1"), FUTURE)
    sessions.create(bob.id, _hash("bob-2"), PAST)

    assert sessions.delete_all_for_user(alice.id) == 2
    assert _remaining_hashes(db_session) == {_hash("bob-1"), _hash("bob-2")}


def test_delete_expired_for_user_never_affects_other_users_or_active_sessions(
    sessions: AuthSessionRepository, alice: User, bob: User, db_session: Session
) -> None:
    sessions.create(alice.id, _hash("alice-expired"), PAST)
    sessions.create(alice.id, _hash("alice-active"), FUTURE)
    sessions.create(bob.id, _hash("bob-expired"), PAST)
    sessions.create(bob.id, _hash("bob-active"), FUTURE)

    assert sessions.delete_expired_for_user(alice.id, NOW) == 1
    assert _remaining_hashes(db_session) == {
        _hash("alice-active"),
        _hash("bob-expired"),
        _hash("bob-active"),
    }


def test_session_expiring_exactly_now_counts_as_expired(
    sessions: AuthSessionRepository, alice: User, db_session: Session
) -> None:
    sessions.create(alice.id, _hash("boundary"), NOW)
    sessions.create(alice.id, _hash("just-after"), NOW + timedelta(microseconds=1))

    assert sessions.delete_expired_for_user(alice.id, NOW) == 1
    assert _remaining_hashes(db_session) == {_hash("just-after")}


def test_delete_expired_accepts_a_caller_supplied_now(
    sessions: AuthSessionRepository, alice: User, db_session: Session
) -> None:
    expires_at = datetime(2030, 1, 1, tzinfo=UTC)
    sessions.create(alice.id, _hash("a"), expires_at)

    assert sessions.delete_expired_for_user(alice.id, expires_at - timedelta(days=1)) == 0
    assert sessions.delete_expired_for_user(alice.id, expires_at) == 1
    assert _remaining_hashes(db_session) == set()


def test_repository_never_commits_or_rolls_back(
    sessions: AuthSessionRepository, alice: User, transaction_spy: list[str]
) -> None:
    sessions.create(alice.id, _hash("a"), FUTURE)
    sessions.create(alice.id, _hash("b"), PAST)
    sessions.get_by_token_hash(_hash("a"))
    sessions.delete_by_token_hash(_hash("a"))
    sessions.delete_expired_for_user(alice.id, NOW)
    sessions.delete_all_for_user(alice.id)

    assert transaction_spy == []
