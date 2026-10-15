# Jarvis

Jarvis is a voice-first personal AI assistant designed primarily for Android.

The long-term goal is an assistant you talk to, backed by an AI orchestrator that
decides which tools or specialised agents are needed to complete a request — for
example searching the web, managing Trello cards or updating an Excel workbook.
Push-to-talk voice conversations are implemented: you can speak Catalan, Spanish,
English or Simplified Chinese, and Jarvis normally replies in Catalan, using Azure AI
Speech and Microsoft Foundry. AI agents, tools and Android assistant integration are
not implemented yet; see the roadmap.

Jarvis is built incrementally, sprint by sprint, as a learning and portfolio project
alongside the Microsoft AI-103 certification.

## Current status

**Sprint 01 — Foundation, authentication and Flutter client (complete).**

Backend:

- [x] FastAPI backend with environment-based settings and `GET /api/health`
- [x] SQLAlchemy 2.x models and Alembic migrations (SQLite locally, PostgreSQL-compatible)
- [x] Authentication API: register, login, current user and logout
- [x] Argon2id password hashing and opaque server-side sessions sent as Bearer tokens

Mobile (Flutter, Android-first):

- [x] Login and registration
- [x] Session restore at startup and token storage in secure storage backed by the
      Android Keystore
- [x] Protected routing: signed-out users only reach login and registration
- [x] Assistant home with a **visual-only** voice button
- [x] Account settings and sign out

**Sprint 02 — Basic AI assistant (complete).**

- [x] Microsoft Foundry integration: Responses API client authenticated with
      Microsoft Entra ID (no API keys), optional and created lazily
- [x] Authenticated text assistant endpoint: `POST /api/assistant/respond`
      (one stateless request, one model reply)
- [x] Flutter assistant API client, and a temporary debug-only text screen to test it
- [x] Text round trip Flutter → FastAPI → Microsoft Foundry → Flutter, verified end to
      end on a physical Android device against the local FastAPI backend and
      Microsoft Foundry deployment
- [x] Azure AI Speech integration: speech-to-text and text-to-speech with the
      `ca-ES-AlbaNeural` voice, authenticated with Microsoft Entra ID (no keys),
      optional and created lazily
- [x] Authenticated voice endpoint: `POST /api/voice/respond` (one WAV recording in,
      one spoken MP3 reply out)
- [x] Push-to-talk in the mobile app: hold the voice button to talk, release to send,
      and hear Jarvis's reply
- [x] Voice round trip phone microphone → FastAPI → Speech → Foundry → Speech → phone
      speaker, verified end to end on a physical Android device
- [x] Multilingual spoken input: Azure AI Speech identifies Catalan, Spanish, English or
      Simplified Chinese at the start of each recording; Jarvis normally replies in
      Catalan, verified on a physical Android device in all four languages

Not implemented yet: AI agents, tools, RAG and Android assistant integration — see the
roadmap. Next: Sprint 03, Android assistant integration.

## Architecture

### Current

```text
Flutter app (Android-first)  ──HTTPS + Authorization: Bearer──▶  FastAPI backend
                                                                   │
                                 controllers → services → repositories → database
```

**Client (implemented).** A native Flutter app, Android-first, keeping the architecture
iOS-compatible where practical. There is no web/browser frontend. See
[mobile/README.md](mobile/README.md).

**Backend (implemented).** An MVC-inspired layered design adapted to FastAPI:

| Layer        | Responsibility                                                    | Status      |
| ------------ | ----------------------------------------------------------------- | ----------- |
| Controllers  | FastAPI routers: HTTP handling, validation, error mapping         | Implemented |
| Schemas      | Pydantic request/response contracts                               | Implemented |
| Services     | Use cases and transaction ownership (auth, assistant, voice)      | Implemented |
| Repositories | Persistence queries; never commit                                 | Implemented |
| Models       | SQLAlchemy ORM models                                             | Implemented |
| Security     | Password hashing, password policy, session tokens                 | Implemented |
| Config       | Settings loaded from environment variables                        | Implemented |
| Integrations | Isolated clients: Foundry, Speech (done); Trello, Graph (planned) | Partial     |

Layers are added only when there is real code that needs them.

### Planned assistant flow

> **Planned — partly implemented.** This is the intended end-to-end design. The voice
> path exists without agents (push-to-talk recording → FastAPI → Azure AI Speech
> language identification and speech-to-text → Foundry model → Azure AI Speech
> text-to-speech → spoken reply); agents and tool calling do not.

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
- Voice currently uses one push-to-talk recording per request; streaming or realtime
  voice may come later.

## Authentication

- Users register with email and password and log in to receive an **opaque session
  token** — a random 256-bit value, **not a JWT**.
- The app keeps the token in secure storage backed by the Android Keystore (Flutter
  Secure Storage) and sends it as `Authorization: Bearer <token>`.
- Sessions are server-side: only a SHA-256 hash of the token is stored, sessions expire
  after 7 days, and logout revokes them immediately.
- Passwords are hashed with Argon2id; the password policy (15–128 characters, no
  composition rules) is aligned with current NIST guidance.
- **Production traffic must use HTTPS.** Plain HTTP is only for local development.

Details: [backend/README.md](backend/README.md#authentication-api).

## Mobile client

The Flutter app is deliberately minimal and voice-first:

- Login and registration screens.
- A main assistant screen centred around a push-to-talk voice button: hold to talk
  in Catalan, Spanish, English or Simplified Chinese, release to send, and Jarvis's
  reply is spoken, normally in Catalan. See
  [mobile/README.md](mobile/README.md#push-to-talk).
- A small settings screen with account details and sign out.
- A temporary, **debug-only** developer screen (Settings → Developer) sends text to
  the assistant and shows the reply. It is kept to test the text path on its own,
  separately from speech.

Future Android integration (planned for Sprint 03, not implemented):

- Making Jarvis selectable as Android's default digital assistant, so it can be
  invoked like the system assistant — for example by long-pressing the power button.
- The exact official Android integration mechanism will be validated on a physical
  Pixel before the production architecture is chosen; the first spike evaluates an
  `ACTION_ASSIST` activity.
- This may require a small native Kotlin layer alongside the Flutter code.

## Tech stack

| Area     | Technology                                                                      |
| -------- | ------------------------------------------------------------------------------- |
| Client   | Flutter 3.47 (Dart), Android-first; Riverpod, go_router, flutter_secure_storage |
| Backend  | Python 3.12+, FastAPI, Pydantic, Uvicorn                                        |
| Database | SQLAlchemy 2.x, Alembic; SQLite locally, PostgreSQL-compatible                  |
| Security | Argon2id (`argon2-cffi`), opaque server-side sessions with Bearer tokens        |
| AI       | Microsoft Foundry (Responses API), Microsoft Entra ID (`azure-identity`)        |
| Speech   | Azure AI Speech: language identification, speech-to-text, text-to-speech        |
| Testing  | pytest and Ruff (backend); flutter test and flutter analyze (mobile)            |

## Local development

- Backend: see [backend/README.md](backend/README.md).
- Mobile app: see [mobile/README.md](mobile/README.md).

## Roadmap

| Sprint | Focus                                                                                                   | Status   |
| ------ | ------------------------------------------------------------------------------------------------------- | -------- |
| 01     | Foundation, authentication API and Flutter client                                                       | Complete |
| 02     | Basic AI assistant: Foundry text, Azure AI Speech, push-to-talk, multilingual input and Catalan replies | Complete |
| 03     | Android assistant integration: default digital assistant, long-press Power → Jarvis                     | Next     |
| 04     | Agent core and tool calling                                                                             | Planned  |
| 05     | Memory: persistent conversations and context                                                            | Planned  |
| 06     | Trello integration                                                                                      | Planned  |
| 07     | Excel / Microsoft Graph integration                                                                     | Planned  |
| 08     | Retrieval (RAG), using Azure AI Search where appropriate                                                | Planned  |
| 09     | Multi-agent orchestration                                                                               | Planned  |

- **Sprint 03** starts with a physical Pixel spike: does Jarvis appear as a digital
  assistant app, can it be selected, does long-press Power invoke it (from a cold and a
  running app), and how does it behave on a locked phone. The production invocation
  architecture, and how a hands-free conversation ends, are designed after that spike.
- **Sprint 04** evaluates Microsoft Foundry Agents, including whether Jarvis's
  persistent instructions should move from `AssistantService` into a versioned Foundry
  Agent definition, and the tool architecture and orchestration.

Later, not yet scheduled: streaming or realtime voice, voice-friendly model output
(fewer Markdown lists), foreign-language speech quality, Docker, Azure deployment,
CI/CD, observability, evaluations, further security hardening (including rate
limiting) and a broader Azure architecture review. The roadmap is provisional.

## Development workflow

- `main` — stable, releasable versions.
- `develop` — integration branch; completed sprints merge here first.
- `sprint/<nn>-<name>` — one branch per sprint.
- `feature/s<nn>-<name>` / `fix/s<nn>-<name>` — independent work inside a sprint.

Commits follow [Conventional Commits](https://www.conventionalcommits.org/).

## License

[MIT](LICENSE)
