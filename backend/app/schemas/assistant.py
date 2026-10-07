from typing import Annotated

from pydantic import BaseModel, ConfigDict, StringConstraints

MAX_MESSAGE_LENGTH = 4000

# Surrounding whitespace is removed before the length limits are checked.
AssistantMessage = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=MAX_MESSAGE_LENGTH)
]


class AssistantRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    message: AssistantMessage


class AssistantResponse(BaseModel):
    reply: str
