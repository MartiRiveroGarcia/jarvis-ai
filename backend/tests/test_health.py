from fastapi.testclient import TestClient

from app import __version__


def test_health_returns_ok_with_app_metadata(client: TestClient) -> None:
    response = client.get("/api/health")

    assert response.status_code == 200
    assert response.headers["content-type"] == "application/json"
    assert response.json() == {
        "status": "ok",
        "app": "Jarvis API (test)",
        "version": __version__,
        "environment": "test",
    }


def test_health_is_only_served_under_api_prefix(client: TestClient) -> None:
    response = client.get("/health")

    assert response.status_code == 404


def test_health_rejects_unsupported_methods(client: TestClient) -> None:
    response = client.post("/api/health")

    assert response.status_code == 405


def test_health_response_schema_is_documented(client: TestClient) -> None:
    schema = client.get("/openapi.json").json()

    response_ref = schema["paths"]["/api/health"]["get"]["responses"]["200"]["content"][
        "application/json"
    ]["schema"]["$ref"]
    assert response_ref.endswith("/HealthResponse")
