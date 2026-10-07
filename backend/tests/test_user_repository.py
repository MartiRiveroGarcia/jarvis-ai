import time
import uuid

import pytest
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.models import User
from app.repositories.user_repository import UserRepository

HASH = "$argon2id$placeholder"


@pytest.fixture
def users(db_session: Session) -> UserRepository:
    return UserRepository(db_session)


def test_create_adds_user_with_normalized_email_and_given_hash(users: UserRepository) -> None:
    user = users.create("  Marti@Example.COM ", HASH)

    assert isinstance(user.id, uuid.UUID)
    assert user.email == "marti@example.com"
    assert user.password_hash == HASH
    assert user.created_at is not None and user.updated_at is not None


def test_create_does_not_commit(users: UserRepository, db_session: Session) -> None:
    user_id = users.create("marti@example.com", HASH).id

    db_session.rollback()

    assert db_session.get(User, user_id) is None


def test_create_with_existing_email_raises_at_flush(users: UserRepository) -> None:
    users.create("marti@example.com", HASH)

    with pytest.raises(IntegrityError):
        users.create(" MARTI@example.com", HASH)


@pytest.mark.parametrize(
    "lookup", ["marti@example.com", "MARTI@Example.com", "  marti@example.com "]
)
def test_get_by_email_normalizes_the_lookup(users: UserRepository, lookup: str) -> None:
    user = users.create("marti@example.com", HASH)

    assert users.get_by_email(lookup) is user


def test_get_by_email_returns_none_for_unknown_email(users: UserRepository) -> None:
    assert users.get_by_email("nobody@example.com") is None


def test_get_by_id_finds_user_or_returns_none(users: UserRepository) -> None:
    user = users.create("marti@example.com", HASH)

    assert users.get_by_id(user.id) is user
    assert users.get_by_id(uuid.uuid4()) is None


def test_update_password_hash_is_persisted_by_service_commit(
    users: UserRepository, db_session: Session
) -> None:
    user = users.create("marti@example.com", HASH)
    db_session.commit()
    previous_updated_at = user.updated_at

    time.sleep(0.01)
    users.update_password_hash(user, "$argon2id$new-placeholder")
    db_session.commit()  # the service's job, done here explicitly
    db_session.expire_all()

    reloaded = users.get_by_id(user.id)
    assert reloaded is not None
    assert reloaded.password_hash == "$argon2id$new-placeholder"
    assert reloaded.updated_at > previous_updated_at


def test_repository_never_commits_or_rolls_back(
    users: UserRepository, transaction_spy: list[str]
) -> None:
    user = users.create("marti@example.com", HASH)
    users.get_by_email("marti@example.com")
    users.get_by_id(user.id)
    users.update_password_hash(user, "$argon2id$new-placeholder")
    with pytest.raises(IntegrityError):
        users.create("marti@example.com", HASH)

    assert transaction_spy == []
