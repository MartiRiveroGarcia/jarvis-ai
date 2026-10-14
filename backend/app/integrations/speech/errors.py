"""Errors raised by the Azure AI Speech integration.

They carry only a fixed message plus diagnostic metadata that contains no user
content or secrets: a short reason code, the Speech SDK error-code name and the
Speech session id. They never include audio, transcripts, the endpoint,
credentials, the SDK's error details or any SDK exception text.
"""

import re

_SAFE_CODE = re.compile(r"[A-Za-z]{1,64}")
_SAFE_SESSION_ID = re.compile(r"[A-Za-z0-9-]{1,64}")


class SpeechError(Exception):
    message = "Speech request failed"

    def __init__(
        self,
        *,
        reason: str,
        code: str | None = None,
        session_id: str | None = None,
    ) -> None:
        super().__init__(self.message)
        self.reason = reason
        self.code = code if code is not None and _SAFE_CODE.fullmatch(code) else None
        self.session_id = (
            session_id
            if session_id is not None and _SAFE_SESSION_ID.fullmatch(session_id)
            else None
        )

    def __str__(self) -> str:
        code = f", {self.code}" if self.code is not None else ""
        return f"{self.message} ({self.reason}{code})"

    def __repr__(self) -> str:
        return f"{type(self).__name__}(reason={self.reason!r}, code={self.code!r})"


class SpeechNotConfiguredError(SpeechError):
    """Local state: no Speech endpoint is configured. Not an upstream failure."""

    message = "Azure Speech is not configured"

    def __init__(self) -> None:
        super().__init__(reason="not_configured")


class SpeechInvalidAudioError(SpeechError):
    """The input is not a supported WAV recording. Raised before Azure is used."""

    message = "The audio is not a supported WAV recording"


class SpeechNoSpeechError(SpeechError):
    message = "No speech was recognized"

    def __init__(self, *, session_id: str | None = None) -> None:
        super().__init__(reason="no_speech", session_id=session_id)


class SpeechTimeoutError(SpeechError):
    message = "Azure Speech did not respond in time"


class SpeechRateLimitedError(SpeechError):
    message = "Azure Speech rate limit reached"


class SpeechUnavailableError(SpeechError):
    """Speech could not be used: credential, auth, connection, configuration or service."""

    message = "Azure Speech is unavailable"


class SpeechBadResponseError(SpeechError):
    message = "Azure Speech returned an unusable result"
