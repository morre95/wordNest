from httpx import AsyncClient


async def test_health_reports_ok(client: AsyncClient) -> None:
    response = await client.get("/api/v1/health")

    assert response.status_code == 200
    body = response.json()
    assert body["success"] is True
    assert body["data"]["status"] == "ok"
    assert body["data"]["environment"] == "test"


async def test_health_needs_no_authentication(client: AsyncClient) -> None:
    # A load balancer has no credentials; a health check it cannot call is
    # worse than no health check.
    response = await client.get("/api/v1/health", headers={})

    assert response.status_code == 200


async def test_every_response_carries_a_request_id(client: AsyncClient) -> None:
    response = await client.get("/api/v1/health")

    assert response.headers["X-Request-Id"]


async def test_a_supplied_request_id_is_echoed(client: AsyncClient) -> None:
    response = await client.get("/api/v1/health", headers={"X-Request-Id": "trace-me"})

    assert response.headers["X-Request-Id"] == "trace-me"
