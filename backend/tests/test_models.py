import time
import uuid
import warnings
from datetime import UTC, datetime, timedelta, timezone

import pytest
from sqlalchemy import delete, func, select
from sqlalchemy.exc import IntegrityError, SAWarning, StatementError
from sqlalchemy.orm import Session

from app.database.types import UTCDateTime, utc_now
from app.models import AuthSession, User


def _user(email: str = "marti@example.com") -> User:
    return User(email=email, password_hash="$argon2id$placeholder")


def _session_for(user: User, token_hash: str = "a" * 64) -> AuthSession:
    return AuthSession(user=user, token_hash=token_hash, expires_at=utc_now() + timedelta(days=7))


def _count_sessions(db_session: Session) -> int:
    return db_session.scalar(select(func.count()).select_from(AuthSession))


def test_new_user_gets_defaults(db_session: Session) -> None:
    user = _user()
    db_session.add(user)
    db_session.commit()
    db_session.refresh(user)

    assert isinstance(user.id, uuid.UUID)
    assert user.is_active is True
    assert user.created_at.tzinfo is UTC
    assert user.updated_at.tzinfo is UTC
    # Each default calls utc_now() separately, so they may differ by microseconds.
    assert timedelta(0) <= user.updated_at - user.created_at < timedelta(seconds=1)


def test_email_is_normalized_on_assignment() -> None:
    assert _user("  Marti@Example.COM ").email == "marti@example.com"


def test_duplicate_email_differing_only_in_case_and_spaces_is_rejected(
    db_session: Session,
) -> None:
    db_session.add(_user("marti@example.com"))
    db_session.commit()

    db_session.add(_user(" MARTI@example.com"))
    with pytest.raises(IntegrityError):
        db_session.commit()


def test_updated_at_advances_on_update_but_created_at_does_not(db_session: Session) -> None:
    user = _user()
    db_session.add(user)
    db_session.commit()
    created_at, updated_at = user.created_at, user.updated_at

    time.sleep(0.01)
    user.is_active = False
    db_session.commit()
    db_session.refresh(user)

    assert user.created_at == created_at
    assert user.updated_at > updated_at


def test_naive_datetimes_are_rejected(db_session: Session) -> None:
    user = _user()
    db_session.add(user)
    db_session.commit()

    db_session.add(AuthSession(user=user, token_hash="a" * 64, expires_at=datetime(2030, 1, 1)))
    with pytest.raises(StatementError, match="Naive datetimes are not allowed"):
        db_session.commit()


def test_aware_datetimes_are_stored_and_returned_as_utc(db_session: Session) -> None:
    user = _user()
    plus_two = timezone(timedelta(hours=2))
    auth_session = AuthSession(
        user=user, token_hash="a" * 64, expires_at=datetime(2030, 1, 1, 12, 0, tzinfo=plus_two)
    )
    db_session.add(auth_session)
    db_session.commit()
    db_session.expire_all()

    reloaded = db_session.get(AuthSession, auth_session.id)

    assert reloaded is not None
    assert reloaded.expires_at == datetime(2030, 1, 1, 10, 0, tzinfo=UTC)
    assert reloaded.expires_at.tzinfo is UTC


def test_utc_datetime_type_is_cache_safe(db_session: Session) -> None:
    assert UTCDateTime.cache_ok is True

    # SQLAlchemy warns when a TypeDecorator without cache_ok is used in a statement.
    with warnings.catch_warnings():
        warnings.simplefilter("error", SAWarning)
        db_session.execute(select(AuthSession).where(AuthSession.expires_at < utc_now()))


def test_duplicate_token_hash_is_rejected(db_session: Session) -> None:
    user = _user()
    db_session.add_all([_session_for(user, "a" * 64), _session_for(user, "a" * 64)])

    with pytest.raises(IntegrityError):
        db_session.commit()


def test_session_requires_an_existing_user(db_session: Session) -> None:
    db_session.add(
        AuthSession(
            user_id=uuid.uuid4(),
            token_hash="a" * 64,
            expires_at=utc_now() + timedelta(days=7),
        )
    )

    with pytest.raises(IntegrityError):
        db_session.commit()


def test_deleting_user_with_sql_cascades_to_sessions(db_session: Session) -> None:
    user = _user()
    db_session.add_all([_session_for(user, "a" * 64), _session_for(user, "b" * 64)])
    db_session.commit()

    db_session.execute(delete(User).where(User.id == user.id))
    db_session.commit()

    assert _count_sessions(db_session) == 0


def test_deleting_user_with_orm_removes_sessions(db_session: Session) -> None:
    user = _user()
    db_session.add(_session_for(user))
    db_session.commit()

    db_session.delete(user)
    db_session.commit()

    assert _count_sessions(db_session) == 0


def test_relationship_links_both_directions(db_session: Session) -> None:
    user = _user()
    auth_session = _session_for(user)
    db_session.add(user)
    db_session.commit()
    db_session.expire_all()

    reloaded_user = db_session.get(User, user.id)
    reloaded_session = db_session.get(AuthSession, auth_session.id)

    assert reloaded_user is not None and reloaded_session is not None
    assert reloaded_user.sessions == [reloaded_session]
    assert reloaded_session.user is reloaded_user
