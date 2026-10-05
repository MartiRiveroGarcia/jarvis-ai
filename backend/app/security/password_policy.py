"""Password policy shared by the service layer and the API request schemas.

Length-only, aligned with current NIST guidance for password-only authentication:
spaces and any Unicode characters are allowed, there are no composition rules, and
passwords are never truncated.
"""

MIN_PASSWORD_LENGTH = 15
MAX_PASSWORD_LENGTH = 128


def password_meets_policy(password: str) -> bool:
    """Return True if the password length (in Unicode code points) is within bounds."""
    return MIN_PASSWORD_LENGTH <= len(password) <= MAX_PASSWORD_LENGTH
