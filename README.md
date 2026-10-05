# Jarvis

Jarvis is a voice-first personal AI assistant designed primarily for Android.

The long-term goal is an assistant you talk to, backed by an AI orchestrator that
decides which tools or specialised agents are needed to complete a request — for
example searching the web, managing Trello cards or updating an Excel workbook. None
of the AI, voice or assistant features exist yet; see the roadmap.

Jarvis is built incrementally, sprint by sprint, as a learning and portfolio project
alongside the Microsoft AI-103 certification.

## Current status

**Sprint 01 — Foundation and authentication (in progress).**

Implemented:

- [x] Repository basics (gitignore, license, README)
- [x] FastAPI backend with environment-based settings and `GET /api/health`
- [x] Database layer: SQLAlchemy 2.x models and Alembic migrations (SQLite locally)
- [x] Authentication API: register, login, current user and logout, using opaque
      server-side sessions sent as Bearer tokens

Planned for this sprint:

- [ ] Flutter Android app: register and log in, store the session token in secure
      storage, a protected main screen, and log out

## Architecture

### Current

```text
Flutter app (Android-first)  ──HTTPS + Authorization: Bearer──▶  FastAPI backend
                                                                   │
                                 controllers → services → repositories → database
```

**Client (planned).** A native Flutter app, Android-first, keeping the architecture
iOS-compatible where practical. There is no web/browser frontend.

**Backend (implemented).** An MVC-inspired layered design adapted to FastAPI:

| Layer        | Responsibility                                              | Status      |
| ------------ | ----------------------------------------------------------- | ----------- |
| Controllers  | FastAPI routers: HTTP handling, validation, error mapping   | Implemented |
| Schemas      | Pydantic request/response contracts                         | Implemented |
| Services     | Use cases and transaction ownership (authentication so far) | Implemented |
| Repositories | Persistence queries; never commit                           | Implemented |
| Models       | SQLAlchemy ORM models                                       | Implemented |
| Security     | Password hashing, password policy, session tokens           | Implemented |
| Config       | Settings loaded from environment variables                  | Implemented |
| Integrations | Isolated clients for Foundry, Trello, Microsoft Graph       | Planned     |

Layers are added only when there is real code that needs them.

### Planned assistant flow

> **Planned — not implemented.** This is the intended end-to-end design; none of it
> exists yet.

```text
Flutter mobile app
        │
        │ voice request
        ▼
FastAPI backend
        │
        ▼
Microsoft Azure / Foundry
        ├── speech-to-text
        ├── agent / orchestration
        ├── tool calling
        └── text-to-speech
        │
        ▼
FastAPI backend
        │
        │ voice response
        ▼
Flutter mobile app
```

- The Flutter app never connects directly to Foundry.
- Azure credentials stay on the server.
- Agent configuration and tool integrations stay on the server.
- The backend is the boundary between the mobile client and Azure services.
- Requests may start as text internally, which is easier to develop and test.
- The exact speech services and realtime architecture may change when the voice sprint
  is implemented.

## Authentication

- Users register with email and password and log in to receive an **opaque session
  token** — a random 256-bit value, **not a JWT**.
- The app stores the token in platform secure storage (Android Keystore via Flutter
  Secure Storage) and sends it as `Authorization: Bearer <token>`.
- Sessions are server-side: only a SHA-256 hash of the token is stored, sessions expire
  after 7 days, and logout revokes them immediately.
- Passwords are hashed with Argon2id; the password policy (15–128 characters, no
  composition rules) is aligned with current NIST guidance.
- **Production traffic must use HTTPS.** Plain HTTP is only for local development.

Details: [backend/README.md](backend/README.md#authentication-api).

## Mobile client (planned)

The Flutter app will be deliberately minimal and voice-driven:

- Register and log in screens.
- A main assistant screen centred around a voice interaction button.
- A small account/settings screen, including logout.

Future Android integration (planned, not implemented):

- Registering Jarvis for Android's assistant role through `VoiceInteractionService`,
  so it can be invoked like the system assistant — for example by long-pressing the
  power button.
- These Android-specific integrations may require a small native Kotlin layer
  alongside the Flutter code.

## Tech stack

| Area     | Technology                                                               |
| -------- | ------------------------------------------------------------------------ |
| Client   | Flutter (Dart), Android-first _(planned)_                                |
| Backend  | Python 3.12+, FastAPI, Pydantic, Uvicorn                                 |
| Database | SQLAlchemy 2.x, Alembic; SQLite locally, PostgreSQL-compatible           |
| Security | Argon2id (`argon2-cffi`), opaque server-side sessions with Bearer tokens |
| AI       | Microsoft Azure / Microsoft Foundry _(planned)_                          |
| Testing  | pytest and Ruff (backend); Flutter testing added with the app            |

## Local development

- Backend: see [backend/README.md](backend/README.md).
- Mobile app: not available yet.

## Roadmap

| Sprint | Focus                                                        | Status      |
| ------ | ------------------------------------------------------------ | ----------- |
| 01     | Foundation, authentication API and Flutter client            | In progress |
| 02     | AI core with Microsoft Foundry                               | Planned     |
| 03     | Agent core and tool calling                                  | Planned     |
| 04     | Trello integration                                           | Planned     |
| 05     | Excel / Microsoft Graph integration                          | Planned     |
| 06     | Multi-agent orchestration                                    | Planned     |
| 07     | Voice interaction                                            | Planned     |
| 08     | Android assistant integration (assistant role, power button) | Planned     |

Later: Docker, Azure deployment, CI/CD, observability, evaluations and security
hardening (including rate limiting). The roadmap is provisional.

## Development workflow

- `main` — stable, releasable versions.
- `develop` — integration branch; completed sprints merge here first.
- `sprint/<nn>-<name>` — one branch per sprint.
- `feature/s<nn>-<name>` / `fix/s<nn>-<name>` — independent work inside a sprint.

Commits follow [Conventional Commits](https://www.conventionalcommits.org/).

## License

[MIT](LICENSE)
