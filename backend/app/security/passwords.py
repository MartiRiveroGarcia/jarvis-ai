from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError
from argon2.profiles import RFC_9106_LOW_MEMORY

# Argon2id, 64 MiB memory, 3 passes, 4 lanes. Pinned explicitly so a library upgrade
# cannot silently change the parameters. Re-benchmark on the production host.
_hasher = PasswordHasher.from_parameters(RFC_9106_LOW_MEMORY)

# Hard-coded on purpose, and not a secret: it was generated once with the parameters
# above from a random, discarded password, so it matches no real password. Verifying
# against it gives unknown-user logins the same Argon2 cost as real ones, from the
# very first request (a lazily computed hash would add a one-time hashing delay).
# Regenerate it whenever the hasher parameters change; a test enforces this.
_DUMMY_PASSWORD_HASH = (
    "$argon2id$v=19$m=65536,t=3,p=4$o6ei6nc/4JS2xBjx+61DFg$"
    "LgT0iS9wR/BGjvI4jMC7LcEbDbAX77wzjoi3qvuW8pc"
)


def hash_password(password: str) -> str:
    """Hash a password with Argon2id and a random salt (PHC string format)."""
    return _hasher.hash(password)


def verify_password(password_hash: str, password: str) -> bool:
    """Return True if the password matches; False on mismatch or a malformed hash."""
    try:
        return _hasher.verify(password_hash, password)
    except (VerificationError, InvalidHashError):
        return False


def password_needs_rehash(password_hash: str) -> bool:
    """Return True if the hash was created with different parameters than the current ones."""
    return _hasher.check_needs_rehash(password_hash)


def verify_dummy_password(password: str) -> None:
    """Spend one Argon2 verification when no user exists, to mask timing differences.

    The result is deliberately discarded: this must never authenticate anyone.
    """
    verify_password(_DUMMY_PASSWORD_HASH, password)
