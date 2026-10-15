"""Transport errors for the voice endpoint.

Only failures that neither the Speech nor the Assistant domain can represent live
here: the request itself is not an acceptable recording upload. Recognition,
assistant and synthesis failures keep their own error types.
"""


class VoiceError(Exception):
    message = "The voice request failed"

    def __init__(self) -> None:
        super().__init__(self.message)


class VoiceUnsupportedMediaError(VoiceError):
    message = "The recording must be a WAV file"


class VoiceTooLargeError(VoiceError):
    message = "The recording is too large"
