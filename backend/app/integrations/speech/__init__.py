"""Azure AI Speech integration (Microsoft Entra ID, custom-domain endpoint).

The native Speech SDK is used only by the internal _sdk module, which the client
imports on first use; importing this package does not load it.
"""

from app.integrations.speech.client import AzureSpeechClient
from app.integrations.speech.errors import (
    SpeechBadResponseError,
    SpeechError,
    SpeechInvalidAudioError,
    SpeechInvalidTextError,
    SpeechNoSpeechError,
    SpeechNotConfiguredError,
    SpeechRateLimitedError,
    SpeechTimeoutError,
    SpeechUnavailableError,
)

__all__ = [
    "AzureSpeechClient",
    "SpeechBadResponseError",
    "SpeechError",
    "SpeechInvalidAudioError",
    "SpeechInvalidTextError",
    "SpeechNoSpeechError",
    "SpeechNotConfiguredError",
    "SpeechRateLimitedError",
    "SpeechTimeoutError",
    "SpeechUnavailableError",
]
