from typing import Annotated

from fastapi import APIRouter, Depends, Request, Response
from starlette.concurrency import run_in_threadpool

from app.dependencies import get_current_user, get_voice_assistant_service
from app.integrations.speech.audio import MAX_WAV_BYTES
from app.models.user import User
from app.services.voice_assistant_service import VoiceAssistantService
from app.services.voice_errors import VoiceTooLargeError, VoiceUnsupportedMediaError

router = APIRouter(prefix="/voice", tags=["voice"])

WAV_MEDIA_TYPE = "audio/wav"
MP3_MEDIA_TYPE = "audio/mpeg"

_OPENAPI = {
    "requestBody": {
        "required": True,
        "content": {WAV_MEDIA_TYPE: {"schema": {"type": "string", "format": "binary"}}},
    }
}


@router.post(
    "/respond",
    response_class=Response,
    responses={
        200: {"content": {MP3_MEDIA_TYPE: {"schema": {"type": "string", "format": "binary"}}}}
    },
    openapi_extra=_OPENAPI,
)
async def respond(
    request: Request,
    user: Annotated[User, Depends(get_current_user)],
    voice_service: Annotated[VoiceAssistantService, Depends(get_voice_assistant_service)],
) -> Response:
    """Answer one spoken message with spoken audio: raw WAV in, raw MP3 out.

    The caller is authenticated before the body is read. The blocking Speech and
    model calls run in the thread pool. Stateless: nothing is stored.
    """
    _check_media_type(request)
    _check_declared_length(request)
    wav = await _read_body(request)
    mp3 = await run_in_threadpool(voice_service.respond, user, wav)
    return Response(content=mp3, media_type=MP3_MEDIA_TYPE)


def _check_media_type(request: Request) -> None:
    media_type = request.headers.get("content-type", "").split(";", 1)[0].strip().lower()
    if media_type != WAV_MEDIA_TYPE:
        raise VoiceUnsupportedMediaError


def _check_declared_length(request: Request) -> None:
    declared = request.headers.get("content-length")
    if declared is not None and declared.isdigit() and int(declared) > MAX_WAV_BYTES:
        raise VoiceTooLargeError


async def _read_body(request: Request) -> bytes:
    """Read the body with a running cap, so an undeclared stream cannot exceed it."""
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > MAX_WAV_BYTES:
            raise VoiceTooLargeError
    return bytes(body)
