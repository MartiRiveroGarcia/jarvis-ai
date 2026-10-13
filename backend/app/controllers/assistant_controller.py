from typing import Annotated

from fastapi import APIRouter, Depends

from app.dependencies import get_assistant_service, get_current_user
from app.models.user import User
from app.schemas.assistant import AssistantRequest, AssistantResponse
from app.services.assistant_service import AssistantService

router = APIRouter(prefix="/assistant", tags=["assistant"])


@router.post("/respond")
def respond(
    body: AssistantRequest,
    user: Annotated[User, Depends(get_current_user)],
    assistant_service: Annotated[AssistantService, Depends(get_assistant_service)],
) -> AssistantResponse:
    """Answer one message. Stateless: nothing is stored and no history is kept.

    A plain (sync) endpoint, so the blocking model call runs in the thread pool.
    """
    return AssistantResponse(reply=assistant_service.respond(user, body.message))
