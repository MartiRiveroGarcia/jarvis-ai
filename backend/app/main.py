from fastapi import FastAPI

from app import __version__
from app.config.settings import get_settings
from app.controllers import health_controller

API_PREFIX = "/api"


def create_app() -> FastAPI:
    """Build and configure the FastAPI application."""
    settings = get_settings()

    app = FastAPI(title=settings.app_name, version=__version__)
    app.include_router(health_controller.router, prefix=API_PREFIX)

    return app


app = create_app()
