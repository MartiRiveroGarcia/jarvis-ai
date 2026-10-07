import re
import uuid
from collections.abc import Callable, Iterator
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from fastapi.security import HTTPAuthorizationCredentials
from fastapi.testclient import TestClient
from httpx2 import Response
from pydantic import SecretStr
from sqlalchemy import event, select, text
from sqlalchemy.orm import Session

from app.config.settings import Settings, get_settings
from app.controllers.error_handlers import AUTH_ERROR_STATUS
from app.database.base import Base
from app.database.session import get_engine, get_session_factory
from app.database.types import utc_now
from app.dependencies import get_bearer_token
from app.main import create_app
from app.models import AuthSession, User
from app.repositories.auth_session_repository import AuthSessionRepository
from app.schemas.auth import LoginResponse, UserResponse
from app.security.session_tokens import (
    SESSION_TOKEN_LENGTH,
    generate_session_token,
    hash_session_token,
)
from app.services import auth_errors

EMAIL = "marti@example.com"
PASSWORD = "correct horse battery staple"
GENERIC_401 = {"detail": "Invalid or expired session"}


# --- fixtures --------------------------------------------------------------------


@pytest.fixture
def api_settings() -> Settings:
    return Settings(_env_file=None, environment="test")


@pytest.fixture
def make_client(database_url: str) -> Iterator[Callable[[Settings], TestClient]]:
    Base.metadata.create_all(get_engine())
    clients: list[TestClient] = []

    def factory(settings: Settings) -> TestClient:
        app = create_app()
        app.dependency_overrides[get_settings] = lambda: settings
        client = TestClient(app)
        clients.append(client)
        return client

    yield factory
    for client in clients:
        client.close()


@pytest.fixture
def api(make_client: Callable[[Settings], TestClient], api_settings: Settings) -> TestClient:
    return make_client(api_settings)


@pytest.fixture
def db() -> Iterator[Session]:
    with get_session_factory()() as session:
        yield session


@pytest.fixture
def sql_log() -> Iterator[list[tuple[str, Any]]]:
    statements: list[tuple[str, Any]] = []

    def record(_conn: Any, _cursor: Any, statement: str, parameters: Any, *_: Any) -> None:
        statements.append((statement, parameters))

    engine = get_engine()
    event.listen(engine, "before_cursor_execute", record)
    yield statements
    event.remove(engine, "before_cursor_execute", record)


def _register(api: TestClient, email: str = EMAIL, password: str = PASSWORD) -> Response:
    return api.post("/api/auth/register", json={"email": email, "password": password})


def _login(api: TestClient, email: str = EMAIL, password: str = PASSWORD) -> Response:
    return api.post("/api/auth/login", json={"email": email, "password": password})


def _token(api: TestClient) -> str:
    _register(api)
    return _login(api).json()["session_token"]


def _bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _all_database_values(db: Session) -> str:
    rows = []
    for table in ("users", "auth_sessions"):
        rows.extend(db.execute(text(f"SELECT * FROM {table}")).all())  # noqa: S608
    return repr(rows)


# --- register --------------------------------------------------------------------


def test_register_returns_201_with_public_user_fields_only(api: TestClient) -> None:
    response = _register(api, email="  Marti@Example.COM ")

    assert response.status_code == 201
    body = response.json()
    assert set(body) == {"id", "email", "created_at"}
    assert body["email"] == EMAIL


@pytest.mark.parametrize(
    ("length", "expected_status"), [(14, 422), (15, 201), (128, 201), (129, 422)]
)
def test_register_password_length_policy(
    api: TestClient, length: int, expected_status: int
) -> None:
    assert _register(api, password="p" * length).status_code == expected_status


@pytest.mark.parametrize("password", ["correct horse battery staple", "contraseña segura 🔐 ñandú"])
def test_register_accepts_spaces_and_unicode(api: TestClient, password: str) -> None:
    assert _register(api, password=password).status_code == 201


def test_register_duplicate_email_returns_409(api: TestClient) -> None:
    _register(api)

    response = _register(api, email=" MARTI@example.com")

    assert response.status_code == 409
    assert response.json() == {"detail": "Email is already registered"}


def test_register_returns_403_when_disabled(
    make_client: Callable[[Settings], TestClient],
) -> None:
    api = make_client(Settings(_env_file=None, environment="test", registration_enabled=False))

    response = _register(api)

    assert response.status_code == 403
    assert response.json() == {"detail": "Registration is disabled"}


def test_register_rejects_unknown_fields(api: TestClient) -> None:
    response = api.post(
        "/api/auth/register", json={"email": EMAIL, "password": PASSWORD, "is_active": False}
    )

    assert response.status_code == 422


def test_register_email_schema_matches_database_column(api: TestClient) -> None:
    schema = api.get("/openapi.json").json()["components"]["schemas"]["RegisterRequest"]

    assert schema["properties"]["email"]["maxLength"] == User.__table__.c.email.type.length == 254


# --- login -----------------------------------------------------------------------


def test_login_returns_opaque_bearer_token_and_user(api: TestClient) -> None:
    _register(api)
    before = datetime.now(UTC)

    response = _login(api)

    assert response.status_code == 200
    body = response.json()
    assert set(body) == {"user", "session_token", "token_type", "expires_at"}
    assert set(body["user"]) == {"id", "email", "created_at"}
    assert body["token_type"] == "bearer"
    assert re.fullmatch(r"[A-Za-z0-9_-]{43}", body["session_token"])
    expires_at = datetime.fromisoformat(body["expires_at"])
    assert before + timedelta(days=7) <= expires_at <= datetime.now(UTC) + timedelta(days=7)


def test_login_response_contains_no_hashes_or_internal_fields(api: TestClient) -> None:
    _register(api)

    raw = _login(api).text

    for forbidden in ("password_hash", "token_hash", "is_active", "updated_at", "$argon2"):
        assert forbidden not in raw


def test_returned_token_matches_stored_hash_and_is_never_persisted(
    api: TestClient, db: Session
) -> None:
    token = _token(api)

    stored = db.scalars(select(AuthSession.token_hash)).one()
    assert stored == hash_session_token(token)
    assert token not in _all_database_values(db)


def test_raw_token_never_reaches_sql_parameters(
    api: TestClient, sql_log: list[tuple[str, Any]]
) -> None:
    token = _token(api)
    api.get("/api/auth/me", headers=_bearer(token))
    api.post("/api/auth/logout", headers=_bearer(token))

    parameters = repr([params for _, params in sql_log])
    assert token not in parameters
    assert hash_session_token(token) in parameters


@pytest.mark.parametrize(
    ("email", "password"),
    [
        ("nobody@example.com", PASSWORD),  # unknown email
        ("not an email", PASSWORD),  # malformed email behaves like an unknown one
    ],
)
def test_unknown_email_and_wrong_password_are_byte_identical(
    api: TestClient, email: str, password: str
) -> None:
    _register(api)

    wrong_password = _login(api, password=PASSWORD + "!")
    unknown = _login(api, email=email, password=password)

    assert wrong_password.status_code == unknown.status_code == 401
    assert wrong_password.content == unknown.content
    assert wrong_password.headers["www-authenticate"] == unknown.headers["www-authenticate"]
    assert wrong_password.json() == {"detail": "Invalid email or password"}


def test_login_with_inactive_account_returns_403(api: TestClient, db: Session) -> None:
    _register(api)
    db.execute(text("UPDATE users SET is_active = 0"))
    db.commit()

    response = _login(api)

    assert response.status_code == 403
    assert response.json() == {"detail": "Account is disabled"}


def test_login_does_not_apply_the_registration_password_minimum(api: TestClient) -> None:
    _register(api)

    response = _login(api, password="short")  # below 15, still reaches the service

    assert response.status_code == 401


def test_login_email_is_case_insensitive(api: TestClient) -> None:
    _register(api)

    assert _login(api, email=" MARTI@Example.com").status_code == 200


# --- token format ----------------------------------------------------------------


@pytest.mark.parametrize(
    "token",
    [
        "A" * (SESSION_TOKEN_LENGTH - 1),  # too short
        "A" * (SESSION_TOKEN_LENGTH + 1),  # too long
        "A" * (SESSION_TOKEN_LENGTH - 1) + "+",  # standard base64, not URL-safe
        "A" * (SESSION_TOKEN_LENGTH - 1) + "=",  # padding
        "A" * (SESSION_TOKEN_LENGTH - 1) + "ñ",  # non-ASCII
        "A" * 20 + " " + "A" * 22,  # embedded space
    ],
    ids=["too-short", "too-long", "plus", "padding", "non-ascii", "space"],
)
def test_malformed_tokens_never_reach_the_database(
    api: TestClient, token: str, sql_log: list[tuple[str, Any]]
) -> None:
    sql_log.clear()

    # Sent as raw UTF-8 bytes: real clients can send non-ASCII header bytes.
    response = api.get("/api/auth/me", headers={"Authorization": f"Bearer {token}".encode()})

    assert response.status_code == 401
    assert response.json() == GENERIC_401
    assert sql_log == []


def test_well_formed_unknown_token_is_looked_up_and_rejected(
    api: TestClient, sql_log: list[tuple[str, Any]]
) -> None:
    token = generate_session_token()

    response = api.get("/api/auth/me", headers=_bearer(token))

    assert response.status_code == 401
    assert any(hash_session_token(token) in repr(params) for _, params in sql_log)


# --- /me -------------------------------------------------------------------------


def test_me_with_valid_bearer_token(api: TestClient) -> None:
    token = _token(api)

    response = api.get("/api/auth/me", headers=_bearer(token))

    assert response.status_code == 200
    assert response.json()["email"] == EMAIL
    assert set(response.json()) == {"id", "email", "created_at"}


def test_bearer_scheme_is_case_insensitive(api: TestClient) -> None:
    token = _token(api)

    assert api.get("/api/auth/me", headers={"Authorization": f"bearer {token}"}).status_code == 200


def _expired_token(db: Session) -> str:
    user = User(email="expired@example.com", password_hash="$argon2id$placeholder")
    db.add(user)
    db.flush()
    token = generate_session_token()
    AuthSessionRepository(db).create(user.id, hash_session_token(token), utc_now())
    db.commit()
    return token


def _inactive_user_token(api: TestClient, db: Session) -> str:
    _register(api, email="disabled@example.com")
    token = _login(api, email="disabled@example.com").json()["session_token"]
    db.execute(text("UPDATE users SET is_active = 0 WHERE email = 'disabled@example.com'"))
    db.commit()
    return token


def test_all_protected_route_failures_are_identical(api: TestClient, db: Session) -> None:
    failures: dict[str, dict[str, str]] = {
        "missing header": {},
        "basic scheme": {"Authorization": "Basic dXNlcjpwYXNz"},
        "scheme only": {"Authorization": "Bearer"},
        "bare token": {"Authorization": generate_session_token()},
        "too short": _bearer("A" * (SESSION_TOKEN_LENGTH - 1)),
        "too long": _bearer("A" * (SESSION_TOKEN_LENGTH + 1)),
        "invalid characters": _bearer("A" * (SESSION_TOKEN_LENGTH - 1) + "+"),
        "unknown token": _bearer(generate_session_token()),
        "expired token": _bearer(_expired_token(db)),
        "inactive user": _bearer(_inactive_user_token(api, db)),
    }

    responses = {name: api.get("/api/auth/me", headers=h) for name, h in failures.items()}

    reference = responses["missing header"]
    assert reference.status_code == 401
    assert reference.json() == GENERIC_401
    assert reference.headers["www-authenticate"] == "Bearer"
    for name, response in responses.items():
        assert response.status_code == reference.status_code, name
        assert response.content == reference.content, name
        assert response.headers["www-authenticate"] == "Bearer", name


def test_expired_session_is_deleted_on_use(api: TestClient, db: Session) -> None:
    token = _expired_token(db)

    api.get("/api/auth/me", headers=_bearer(token))

    db.expire_all()
    assert db.scalars(select(AuthSession)).all() == []


# --- logout ----------------------------------------------------------------------


def test_logout_revokes_the_server_side_session(api: TestClient, db: Session) -> None:
    token = _token(api)

    response = api.post("/api/auth/logout", headers=_bearer(token))

    assert response.status_code == 204
    assert response.content == b""
    assert db.scalars(select(AuthSession)).all() == []
    assert api.get("/api/auth/me", headers=_bearer(token)).status_code == 401


def test_logout_is_idempotent(api: TestClient) -> None:
    token = _token(api)

    assert api.post("/api/auth/logout", headers=_bearer(token)).status_code == 204
    assert api.post("/api/auth/logout", headers=_bearer(token)).status_code == 204


@pytest.mark.parametrize(
    "headers",
    [
        {},
        {"Authorization": "Bearer"},
        {"Authorization": "Basic dXNlcjpwYXNz"},
        {"Authorization": "Bearer not-a-valid-token"},
        {"Authorization": f"Bearer {generate_session_token()}"},
    ],
    ids=["missing", "scheme-only", "basic", "malformed-token", "unknown-token"],
)
def test_logout_without_valid_credentials_returns_204(
    api: TestClient, headers: dict[str, str]
) -> None:
    response = api.post("/api/auth/logout", headers=headers)

    assert response.status_code == 204
    assert response.content == b""


def test_logout_with_malformed_token_never_reaches_the_database(
    api: TestClient, sql_log: list[tuple[str, Any]]
) -> None:
    api.post("/api/auth/logout", headers=_bearer("not-a-valid-token"))

    assert sql_log == []


def test_logout_only_revokes_that_session(api: TestClient) -> None:
    first = _token(api)
    second = _login(api).json()["session_token"]

    api.post("/api/auth/logout", headers=_bearer(first))

    assert api.get("/api/auth/me", headers=_bearer(second)).status_code == 200


# --- error mapping, validation and headers ----------------------------------------


def test_every_auth_error_has_an_http_mapping() -> None:
    domain_errors = {
        obj
        for obj in vars(auth_errors).values()
        if isinstance(obj, type)
        and issubclass(obj, auth_errors.AuthError)
        and obj is not auth_errors.AuthError
    }

    assert domain_errors == set(AUTH_ERROR_STATUS)


@pytest.mark.parametrize(
    ("path", "payload", "secret"),
    [
        ("/api/auth/register", {"email": EMAIL, "password": "tooShortSecret"}, "tooShortSecret"),
        ("/api/auth/register", {"email": "bad-email-xyz", "password": PASSWORD}, "bad-email-xyz"),
        ("/api/auth/login", {"email": EMAIL, "password": "p" * 1025}, "p" * 1025),
        ("/api/auth/login", {"email": EMAIL, "password": "pw", "extra": "leak-me"}, "leak-me"),
    ],
)
def test_validation_errors_never_echo_submitted_values(
    api: TestClient, path: str, payload: dict[str, str], secret: str
) -> None:
    response = api.post(path, json=payload)

    assert response.status_code == 422
    assert secret not in response.text
    for error in response.json()["detail"]:
        assert set(error) == {"loc", "msg", "type"}


def test_validation_error_keeps_location_and_message(api: TestClient) -> None:
    response = _register(api, password="tooShortSecret")

    [error] = response.json()["detail"]
    assert error["loc"] == ["body", "password"]
    assert error["type"] == "string_too_short"
    assert "15" in error["msg"]


def test_invalid_json_body_is_not_echoed(api: TestClient) -> None:
    response = api.post(
        "/api/auth/login",
        content=b'{"email": "a@b.c", "password": "s3cret-in-broken-json"',
        headers={"Content-Type": "application/json"},
    )

    assert response.status_code == 422
    assert "s3cret-in-broken-json" not in response.text


def test_auth_responses_are_not_cacheable(api: TestClient) -> None:
    token = _token(api)
    responses = [
        _register(api, email="other@example.com"),  # 201
        _login(api),  # 200
        _login(api, password="wrong password!!"),  # 401
        _register(api),  # 409
        _register(api, password="short"),  # 422
        api.get("/api/auth/me", headers=_bearer(token)),  # 200
        api.get("/api/auth/me"),  # 401
        api.post("/api/auth/logout", headers=_bearer(token)),  # 204
    ]

    for response in responses:
        assert response.headers["cache-control"] == "no-store", response.status_code


def test_health_response_is_unchanged(api: TestClient) -> None:
    response = api.get("/api/health")

    assert response.status_code == 200
    assert "cache-control" not in response.headers


def test_login_response_object_does_not_expose_token_in_repr() -> None:
    token = generate_session_token()
    response = LoginResponse(
        user=UserResponse(id=uuid.uuid4(), email=EMAIL, created_at=utc_now()),
        session_token=SecretStr(token),
        expires_at=utc_now(),
    )

    assert token not in repr(response)
    assert token not in str(response)
    assert token in response.model_dump_json()


# --- OpenAPI ---------------------------------------------------------------------


def test_openapi_documents_bearer_security(api: TestClient) -> None:
    schema = api.get("/openapi.json").json()

    assert schema["components"]["securitySchemes"]["HTTPBearer"]["type"] == "http"
    assert schema["components"]["securitySchemes"]["HTTPBearer"]["scheme"] == "bearer"
    assert schema["paths"]["/api/auth/me"]["get"]["security"] == [{"HTTPBearer": []}]
    assert schema["paths"]["/api/auth/logout"]["post"]["security"] == [{"HTTPBearer": []}]


def test_openapi_response_schemas_expose_no_secrets(api: TestClient) -> None:
    schemas = api.get("/openapi.json").json()["components"]["schemas"]

    for name in ("UserResponse", "LoginResponse"):
        properties = set(schemas[name]["properties"])
        assert not properties & {"password_hash", "token_hash", "is_active", "password"}
    token_field = schemas["LoginResponse"]["properties"]["session_token"]
    assert token_field["type"] == "string"
    assert "writeOnly" not in token_field
    holders = [n for n, s in schemas.items() if "session_token" in s.get("properties", {})]
    assert holders == ["LoginResponse"]


# --- get_bearer_token (HTTP-level format check, independent of the service guard) --


@pytest.mark.parametrize(
    ("credentials", "expected"),
    [
        (None, None),
        (HTTPAuthorizationCredentials(scheme="Bearer", credentials="too-short"), None),
        (HTTPAuthorizationCredentials(scheme="Bearer", credentials="A" * 42 + "+"), None),
        (
            HTTPAuthorizationCredentials(scheme="Bearer", credentials="Ab-_" * 10 + "xyz"),
            "Ab-_" * 10 + "xyz",
        ),
    ],
    ids=["missing", "too-short", "invalid-char", "valid"],
)
def test_get_bearer_token_only_returns_well_formed_tokens(
    credentials: HTTPAuthorizationCredentials | None, expected: str | None
) -> None:
    assert get_bearer_token(credentials) == expected
