# Jarvis backend

FastAPI service that will host Jarvis's API, AI logic and integrations.
It currently exposes a single health check endpoint.

## Requirements

- Python 3.12 or newer (developed and tested with 3.13)

## Setup

All commands are run from the `backend/` directory.

```bash
python3 -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r requirements-dev.txt
cp .env.example .env
```

`requirements.txt` contains runtime dependencies only; `requirements-dev.txt` adds the
testing and linting tools.

## Run

```bash
uvicorn app.main:app --reload
```

- Health check: <http://localhost:8000/api/health>
- Interactive API docs: <http://localhost:8000/docs>

Example response:

```json
{
  "status": "ok",
  "app": "Jarvis API",
  "version": "0.1.0",
  "environment": "development"
}
```

## Test and lint

```bash
pytest                # run the test suite
ruff check .          # lint
ruff format .         # format
```

## Configuration

Settings are read from environment variables prefixed with `JARVIS_`, or from
`backend/.env`. Real environment variables take precedence over the `.env` file.

| Variable             | Default       | Description                                    |
| -------------------- | ------------- | ---------------------------------------------- |
| `JARVIS_APP_NAME`    | `Jarvis API`  | Name shown in the API docs and health response |
| `JARVIS_ENVIRONMENT` | `development` | One of `development`, `test`, `production`     |

`.env` is ignored by Git. Never commit secrets; add new variables to `.env.example`
with a placeholder value instead.

## Structure

```text
app/
├── main.py           # create_app() factory: builds the app and registers routers
├── config/           # environment-based settings
├── controllers/      # FastAPI routers (HTTP layer)
└── models/           # Pydantic schemas
tests/                # pytest suite
```

Further layers (`services/`, `integrations/`, `repositories/`) will be added in later
sprints, when there is real logic to put in them.
