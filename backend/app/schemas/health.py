from typing import Literal

from pydantic import BaseModel


class HealthResponse(BaseModel):
    """Response body of the health check endpoint."""

    status: Literal["ok"]
    app: str
    version: str
    environment: str
