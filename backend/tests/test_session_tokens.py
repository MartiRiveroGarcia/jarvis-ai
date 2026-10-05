import base64
import re

from app.models import AuthSession
from app.security.session_tokens import (
    SESSION_TOKEN_BYTES,
    generate_session_token,
    hash_session_token,
)


def test_token_is_url_safe_and_carries_32_random_bytes() -> None:
    token = generate_session_token()

    assert re.fullmatch(r"[A-Za-z0-9_-]{43}", token)
    assert len(base64.urlsafe_b64decode(token + "=")) == 32


def test_token_entropy_is_at_least_256_bits() -> None:
    assert SESSION_TOKEN_BYTES * 8 >= 256


def test_tokens_are_unique() -> None:
    tokens = {generate_session_token() for _ in range(1000)}

    assert len(tokens) == 1000


def test_hash_matches_sha256_test_vector() -> None:
    assert (
        hash_session_token("abc")
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )


def test_hash_is_deterministic_and_distinct_per_token() -> None:
    token, other = generate_session_token(), generate_session_token()

    assert hash_session_token(token) == hash_session_token(token)
    assert hash_session_token(token) != hash_session_token(other)


def test_hash_fits_the_token_hash_column() -> None:
    token_hash = hash_session_token(generate_session_token())

    assert re.fullmatch(r"[0-9a-f]{64}", token_hash)
    assert len(token_hash) == AuthSession.__table__.c.token_hash.type.length


def test_hash_does_not_contain_the_raw_token() -> None:
    token = generate_session_token()

    assert token not in hash_session_token(token)


def test_non_ascii_token_is_hashed_without_raising() -> None:
    assert re.fullmatch(r"[0-9a-f]{64}", hash_session_token("cookie-ñ-✓"))


def test_auth_session_model_stores_only_a_token_hash() -> None:
    columns = set(AuthSession.__table__.columns.keys())

    assert "token_hash" in columns
    assert not {name for name in columns if "token" in name} - {"token_hash"}
