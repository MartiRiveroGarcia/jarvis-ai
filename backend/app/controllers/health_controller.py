from typing import Annotated

from fastapi import APIRouter, Depends

from app import __version__
from app.config.settings import Settings, get_settings
from app.schemas.health import HealthResponse

router = APIRouter(tags=["health"])


@router.get("/health")
def get_health(settings: Annotated[Settings, Depends(get_settings)]) -> HealthResponse:
    """Report that the API is running, along with basic build information."""
    return HealthResponse(
        status="ok",
        app=settings.app_name,
        version=__version__,
        environment=settings.environment,
    )
