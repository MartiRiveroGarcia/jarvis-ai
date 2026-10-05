"""Domain errors raised by AuthService.

Messages are deliberately generic and never include emails, passwords or tokens.
Controllers translate these into HTTP responses.
"""

from app.security.password_policy import MAX_PASSWORD_LENGTH, MIN_PASSWORD_LENGTH


class AuthError(Exception):
    """Base class for authentication failures."""


class RegistrationDisabledError(AuthError):
    def __init__(self) -> None:
        super().__init__("Registration is disabled")


class InvalidPasswordError(AuthError):
    def __init__(self) -> None:
        super().__init__(
            f"Password must be between {MIN_PASSWORD_LENGTH} and "
            f"{MAX_PASSWORD_LENGTH} characters long"
        )


class EmailAlreadyRegisteredError(AuthError):
    def __init__(self) -> None:
        super().__init__("Email is already registered")


class InvalidCredentialsError(AuthError):
    def __init__(self) -> None:
        super().__init__("Invalid email or password")


class AccountDisabledError(AuthError):
    def __init__(self) -> None:
        super().__init__("Account is disabled")


class InvalidSessionError(AuthError):
    def __init__(self) -> None:
        super().__init__("Invalid or expired session")
