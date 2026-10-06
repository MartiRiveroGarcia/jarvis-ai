/// Registration password rule, mirroring the backend's shared policy
/// (backend/app/security/password_policy.py). The backend remains the authority;
/// this only gives immediate feedback in the form.
const minPasswordLength = 15;
const maxPasswordLength = 128;
