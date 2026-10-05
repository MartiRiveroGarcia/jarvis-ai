import hashlib
import math
import re
import secrets

# 32 random bytes = 256 bits of entropy.
SESSION_TOKEN_BYTES = 32
# Unpadded URL-safe base64 length of SESSION_TOKEN_BYTES (43 for 32 bytes).
SESSION_TOKEN_LENGTH = math.ceil(SESSION_TOKEN_BYTES * 4 / 3)
_SESSION_TOKEN_PATTERN = re.compile(rf"[A-Za-z0-9_-]{{{SESSION_TOKEN_LENGTH}}}")


def generate_session_token() -> str:
    """Return a new random session token (43 URL-safe base64 characters).

    The raw token is returned once in the login response and then sent back by the
    client as a Bearer credential; never store or log it.
    """
    return secrets.token_urlsafe(SESSION_TOKEN_BYTES)


def hash_session_token(token: str) -> str:
    """Return the SHA-256 hex digest stored in the database instead of the token.

    A fast, unsalted hash is appropriate here: the token is 256 random bits, so it
    cannot be guessed, and a deterministic hash allows lookup by unique index.
    """
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def is_well_formed_session_token(token: str) -> bool:
    """Return True if the value could be a token from generate_session_token().

    Lets callers reject obviously invalid credentials without touching the database.
    """
    return _SESSION_TOKEN_PATTERN.fullmatch(token) is not None
