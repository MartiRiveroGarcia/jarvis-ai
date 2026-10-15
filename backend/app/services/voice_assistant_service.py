"""Voice conversation: one recording in, one spoken reply out.

Speech-to-text, the existing assistant and text-to-speech in sequence, with one
Speech client for both directions. Stateless: no history, nothing stored. Speech
and assistant errors propagate unchanged; failures are logged with metadata only.
"""

import logging
from collections.abc import Callable
from typing import Protocol

from app.integrations.speech.errors import (
    SpeechError,
    SpeechInvalidAudioError,
    SpeechNoSpeechError,
    SpeechNotConfiguredError,
)
from app.models.user import User
from app.services.assistant_service import AssistantService

logger = logging.getLogger("jarvis.voice")

# Expected outcomes of a user's recording or local configuration, not upstream faults.
_INFO_ERRORS = (SpeechNotConfiguredError, SpeechInvalidAudioError, SpeechNoSpeechError)


class SpeechClient(Protocol):
    def transcribe(self, wav: bytes) -> str: ...
    def synthesize(self, text: str) -> bytes: ...


# Returns the Speech client; may raise SpeechNotConfiguredError.
SpeechClientProvider = Callable[[], SpeechClient]


class VoiceAssistantService:
    def __init__(
        self, speech_provider: SpeechClientProvider, assistant_service: AssistantService
    ) -> None:
        self._speech_provider = speech_provider
        self._assistant_service = assistant_service

    def respond(self, user: User, wav: bytes) -> bytes:
        """Return MP3 audio answering the WAV recording. Raises Speech or Assistant errors."""
        stage = "stt"
        try:
            speech = self._speech_provider()
            transcript = speech.transcribe(wav)
            stage = "assistant"
            # The assistant logs its own failures; they propagate unchanged.
            reply = self._assistant_service.respond(user, transcript)
            stage = "tts"
            return speech.synthesize(reply)
        except SpeechError as error:
            _log_failure(stage, error)
            raise


def _log_failure(stage: str, error: SpeechError) -> None:
    """One line of fixed metadata; never audio, text, sizes or SDK details."""
    level = logging.INFO if isinstance(error, _INFO_ERRORS) else logging.WARNING
    logger.log(
        level,
        "voice request failed: stage=%s error=%s reason=%s code=%s",
        stage,
        type(error).__name__,
        error.reason,
        error.code,
    )
