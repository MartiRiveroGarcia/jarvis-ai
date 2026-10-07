import pytest
from argon2 import PasswordHasher, extract_parameters

from app.models import User
from app.security import passwords
from app.security.passwords import (
    hash_password,
    password_needs_rehash,
    verify_dummy_password,
    verify_password,
)

PASSPHRASE = "correct horse battery staple ñ"


def _hasher_parameters(password_hash: str) -> tuple[object, ...]:
    p = extract_parameters(password_hash)
    return (p.type, p.version, p.time_cost, p.memory_cost, p.parallelism, p.hash_len, p.salt_len)


def test_hash_uses_pinned_argon2id_parameters() -> None:
    assert hash_password(PASSPHRASE).startswith("$argon2id$v=19$m=65536,t=3,p=4$")


def test_hash_does_not_contain_the_password() -> None:
    assert PASSPHRASE not in hash_password(PASSPHRASE)


def test_same_password_gets_a_different_salt_each_time() -> None:
    first, second = hash_password(PASSPHRASE), hash_password(PASSPHRASE)

    assert first != second
    assert verify_password(first, PASSPHRASE)
    assert verify_password(second, PASSPHRASE)


def test_correct_password_verifies() -> None:
    assert verify_password(hash_password(PASSPHRASE), PASSPHRASE) is True


def test_wrong_password_does_not_verify() -> None:
    assert verify_password(hash_password(PASSPHRASE), PASSPHRASE + "!") is False


@pytest.mark.parametrize(
    "malformed_hash",
    [
        "not-a-hash",  # raises InvalidHashError inside argon2-cffi
        "$argon2id$v=19$m=65536,t=3,p=4$broken",  # raises VerificationError
        "",
    ],
)
def test_malformed_hash_returns_false_instead_of_raising(malformed_hash: str) -> None:
    assert verify_password(malformed_hash, PASSPHRASE) is False


def test_current_hash_does_not_need_rehash() -> None:
    assert password_needs_rehash(hash_password(PASSPHRASE)) is False


def test_hash_with_older_parameters_needs_rehash_but_still_verifies() -> None:
    old_hash = PasswordHasher(time_cost=2, memory_cost=19456, parallelism=1).hash(PASSPHRASE)

    assert password_needs_rehash(old_hash) is True
    assert verify_password(old_hash, PASSPHRASE) is True


def test_dummy_hash_parameters_match_production_hasher() -> None:
    assert _hasher_parameters(passwords._DUMMY_PASSWORD_HASH) == _hasher_parameters(
        hash_password(PASSPHRASE)
    )
    assert password_needs_rehash(passwords._DUMMY_PASSWORD_HASH) is False


def test_dummy_verification_performs_exactly_one_argon2_verification(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    real_hasher = passwords._hasher
    calls: list[str] = []

    class SpyHasher:
        """Records verify() calls and delegates to the real Argon2 hasher."""

        def verify(self, password_hash: str, password: str) -> bool:
            calls.append(password_hash)
            return real_hasher.verify(password_hash, password)

    monkeypatch.setattr(passwords, "_hasher", SpyHasher())

    verify_dummy_password(PASSPHRASE)

    assert calls == [passwords._DUMMY_PASSWORD_HASH]


@pytest.mark.parametrize("password", ["", PASSPHRASE, "x" * 128, "\x00 null byte"])
def test_dummy_verification_never_raises_or_authenticates(password: str) -> None:
    assert verify_dummy_password(password) is None


def test_user_model_stores_only_a_password_hash() -> None:
    columns = set(User.__table__.columns.keys())

    assert "password_hash" in columns
    assert not {name for name in columns if "password" in name} - {"password_hash"}
