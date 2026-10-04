# Jarvis

Jarvis is a personal AI assistant designed to be used primarily from a mobile phone.

The long-term goal is an assistant you can talk to by text or voice, backed by an AI
orchestrator that decides which tools or specialised agents are needed to complete a
request — for example searching the web, managing Trello cards or updating an Excel
workbook.

Jarvis is built incrementally, sprint by sprint, as a learning and portfolio project
alongside the Microsoft AI-103 certification.

## Current status

**Sprint 01 — Foundation (in progress).**

There are no user-facing features yet. This sprint establishes the repository
structure, a FastAPI backend, a React frontend and the communication between them.

## Tech stack

| Area     | Technology                                              |
| -------- | ------------------------------------------------------- |
| Backend  | Python 3, FastAPI, Pydantic, Uvicorn                    |
| Frontend | React, Vite, TypeScript, Tailwind CSS (mobile-first)    |
| AI       | Microsoft Azure / Microsoft Foundry _(planned)_         |
| Testing  | pytest (backend); frontend tooling added when needed    |

## Architecture

The backend follows an MVC-inspired layered design adapted to FastAPI:

| Layer        | Responsibility                                            |
| ------------ | --------------------------------------------------------- |
| Models       | Pydantic schemas and domain entities                      |
| Controllers  | FastAPI routers: HTTP handling and validation             |
| Services     | Business logic, AI logic and orchestration _(planned)_    |
| Repositories | Persistence, once a database is introduced _(planned)_    |
| Integrations | Isolated clients for Foundry, Trello, Graph _(planned)_   |
| Config       | Settings loaded from environment variables                |

Layers are added only when there is real code that needs them.

## Roadmap

| Sprint | Focus                                      | Status      |
| ------ | ------------------------------------------ | ----------- |
| 01     | Foundation                                 | In progress |
| 02     | AI chat with Microsoft Foundry             | Planned     |
| 03     | Agent core and tool calling                | Planned     |
| 04     | Trello integration                         | Planned     |
| 05     | Excel / Microsoft Graph integration        | Planned     |
| 06     | Multi-agent orchestration                  | Planned     |
| 07     | Voice input                                | Planned     |
| 08     | Authentication and persistence             | Planned     |

Later: Docker, Azure deployment, CI/CD, observability, evaluations and security
hardening. The roadmap is provisional.

## Development workflow

- `main` — stable, releasable versions.
- `develop` — integration branch; completed sprints merge here first.
- `sprint/<nn>-<name>` — one branch per sprint.
- `feature/s<nn>-<name>` / `fix/s<nn>-<name>` — independent work inside a sprint.

Commits follow [Conventional Commits](https://www.conventionalcommits.org/).

## License

[MIT](LICENSE)
