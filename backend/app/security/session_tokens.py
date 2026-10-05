import hashlib
import secrets

# 32 random bytes = 256 bits of entropy.
SESSION_TOKEN_BYTES = 32


def generate_session_token() -> str:
    """Return a new random session token (43 URL-safe base64 characters).

    The raw token is only ever sent to the client in a cookie; never store it.
    """
    return secrets.token_urlsafe(SESSION_TOKEN_BYTES)


def hash_session_token(token: str) -> str:
    """Return the SHA-256 hex digest stored in the database instead of the token.

    A fast, unsalted hash is appropriate here: the token is 256 random bits, so it
    cannot be guessed, and a deterministic hash allows lookup by unique index.
    """
    return hashlib.sha256(token.encode("utf-8")).hexdigest()
