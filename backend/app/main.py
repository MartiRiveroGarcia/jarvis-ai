from fastapi import FastAPI

from app import __version__
from app.config.settings import get_settings
from app.controllers import assistant_controller, auth_controller, health_controller
from app.controllers.error_handlers import register_error_handlers

API_PREFIX = "/api"


def create_app() -> FastAPI:
    """Build and configure the FastAPI application."""
    settings = get_settings()

    app = FastAPI(title=settings.app_name, version=__version__)
    app.include_router(health_controller.router, prefix=API_PREFIX)
    app.include_router(auth_controller.router, prefix=API_PREFIX)
    app.include_router(assistant_controller.router, prefix=API_PREFIX)
    register_error_handlers(app)

    return app


app = create_app()
