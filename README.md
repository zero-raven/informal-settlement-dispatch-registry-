# Informal Settlement Registry & Emergency Dispatch System

A semester project for mapping informal settlements and managing emergency dispatch workflows. Built with a Node.js backend API and a Flutter frontend (Linux desktop + Android APK).

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            BACKEND (Node.js)                                │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌──────────────────┐  │
│  │  Registry   │  │  Dispatch   │  │  Grievance  │  │     Sync/Tasks   │  │
│  │   API       │  │   Engine    │  │   Triage    │  │     Workers      │  │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └────────┬─────────┘  │
│         │                │                │                   │           │
│         ▼                ▼                ▼                   ▼           │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                    SQLite / PostgreSQL / MongoDB                     │  │
│  │  structures · zones · grievances · dispatches · outcomes · tasks    │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                              REST API (port 8090)
                                    │
┌─────────────────────────────────────────────────────────────────────────────┐
│                          FRONTEND (Flutter)                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │
│  │   Caller     │  │  Dispatcher  │  │    Admin     │  │   Shared     │   │
│  │  (Citizen)   │  │  (Operator)  │  │  (Manager)   │  │  Components  │   │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘   │
│         │                 │                 │                 │           │
│         ▼                 ▼                 ▼                 ▼           │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  6-Tab Navigation  │  Role-Based Access  │  Dark Theme (#0f1115)    │  │
│  │  [Calls]           │  • Caller: Calls    │  Accent: #2ec4b6 (teal)   │  │
│  │  [Dashboard]*      │  • Dispatcher: All  │  Google Fonts (Inter)     │  │
│  │  [Lookup]*         │  • Admin: All       │  Responsive (768px)       │  │
│  │  [Create]*         │                     │  Shimmer Loading          │  │
│  │  [History]*        │  *Dispatcher+ only  │  Pull-to-Refresh          │  │
│  │  [Settings]*       │                     │                           │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Features

### Backend (REST API)
| Module | Endpoints | Description |
|--------|-----------|-------------|
| **Registry** | `GET /v1/zones`, `GET /v1/structures`, `GET /v1/structures/:code` | Zone/structure catalog with GeoJSON |
| **Dispatch** | `POST /v1/dispatch/lookup`, `POST /v1/dispatch/assign`, `POST /v1/dispatch/outcome`, `GET /v1/dispatch/stats`, `GET /v1/dispatch/recent` | Foot/vehicle routing, responder assignment, outcome tracking |
| **Grievance** | `POST /v1/grievances`, `GET /v1/grievances`, `POST /v1/grievances/:id/triage` | Emergency call intake, rule-based triage state machine (no ML classifier) |
| **Sync** | `GET /v1/sync/bootstrap?zone=`, `GET /v1/tasks`, `POST /v1/tasks/:id/complete` | Offline-first sync, mapper task queue |
| **Auth** | `POST /v1/auth/login`, `GET /v1/auth/me`, `POST /v1/auth/refresh` | Signed bearer tokens; role verified server-side from the token. Demo accounts in `services/registry-api/src/auth.js`. Set `AUTH_SECRET` in production. |

### Frontend (Flutter)
- **Role-based UI**: Caller sees only Calls tab; Dispatcher/Admin see all 6 tabs
- **Calls Tab**: Log emergency calls (type/priority/location/description), view own/all calls
- **Dashboard**: Real-time stats, recent dispatches, quick actions, backend status
- **Lookup**: Structure search by code, route preview (foot/vehicle), Reached/Failed outcomes
- **Create Dispatch**: Manual dispatch creation from structures, pending dispatch list
- **History**: Searchable/filterable log (All/Active/Completed/Failed), detail sheets
- **Settings**: API URLs, theme (Light/Dark/System), behavior toggles, connection test
- **Design System**: Consistent spacing (4px), typography, shadows, animations, breakpoints


### Information architecture by role

| Role | Sees | Why |
|---|---|---|
| **Caller** (dispatcher app) | Calls only | Report an emergency and track it. No structure, dispatch, or service data — that is sensitive operational information (§6.6). |
| **Dispatcher / Admin** | Calls, Dashboard, Lookup, **Map**, Create, History, Settings | Coordinate the response: stats, code lookup + route, settlement map (structures + breadcrumb walks), assignment, outcomes, history. |
| **Mapper** (separate app) | Map, Walk, Capture, Sync | Field work only: offline vector map, GPS breadcrumb recording, structure capture, opportunistic sync. No dispatch or identity data. |

### Offline GPS mapping (mapper)
- **Walk recording**: device GPS (geolocator, best-for-navigation, ~3 m filter) writes breadcrumb points to local SQLite immediately — no connectivity required.
- **Outbox**: each point queues a `breadcrumb` sync op; structures queue `local_structure` ops. Nothing is uploaded until the mapper reconnects and sets the registry URL (Settings in the Sync section, persisted).
- **Sync**: `POST /v1/sync/push` with `table: breadcrumb` stores points server-side (idempotent by `clientOpId` and `(device, trace, seq)`); `GET /v1/breadcrumbs` serves them for the dispatcher Map and path-graph builds.
- **Map**: a local vector canvas (no network tiles) draws structures, the walk polyline, live position, north arrow and scale — it shows exactly what the device knows offline.

### Build Targets
| Platform | Command | Output |
|----------|---------|--------|
| Linux Desktop | `flutter build linux` | `build/linux/x64/release/bundle/dispatcher` (~23KB) |
| Android APK | `flutter build apk` | `build/app/outputs/flutter-apk/app-release.apk` (~21MB) |

---

## Quick Start

### Prerequisites
- **Node.js** 18+ (for backend)
- **Flutter** 3.24+ (for frontend) — install via `scripts/setup-flutter.sh`
- **Android SDK** (for APK) — `flutter config --android-sdk ~/Android/Sdk`
- **GTK3** (for Linux build) — `sudo pacman -S gtk3` (Arch) / `apt install libgtk-3-dev` (Debian)

### 1. Start Backend
```bash
cd /home/Kaiser/clg/el
DB_PATH=/tmp/registry.db PORT=8090 node services/registry-api/src/server.js
# → "registry-api listening on :8090"
```

Note: a fresh SQLite DB starts empty. Seed data (Zone C4 + 5 structures) lives in the Postgres migration `services/registry-api/migrations/000_init.sql`, not in the SQLite runtime.

### 2. Run Frontend (Linux)
```bash
cd /home/Kaiser/clg/el/apps/dispatcher
export PATH="/home/Kaiser/clg/el/.cache/flutter/bin:$PATH"
flutter build linux
./build/linux/x64/release/bundle/dispatcher
```
First launch → Select role (Caller/Dispatcher/Admin) → Enter name → Start

### 3. Build Android APK
```bash
cd /home/Kaiser/clg/el/apps/dispatcher
export PATH="/home/Kaiser/clg/el/.cache/flutter/bin:$PATH"
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk
export ANDROID_HOME=~/Android/Sdk
flutter build apk
# → build/app/outputs/flutter-apk/app-release.apk
```
Install on phone: `adb install app-release.apk` or transfer via file share.
Set API URL in Settings → `http://<laptop-lan-ip>:8090`

---

## API Examples

```bash
# Health check
curl http://127.0.0.1:8090/v1/dispatch/capabilities

# Log emergency call (Caller)
curl -X POST http://127.0.0.1:8090/v1/grievances \
  -H "Content-Type: application/json" \
  -d '{"device_hash":"caller_123","reported_location":{"lat":12.97,"lon":77.59},"body":"Fire near SLR-C41001"}'

# List calls (Dispatcher)
curl -H "X-Role: dispatcher" http://127.0.0.1:8090/v1/grievances

# Lookup structure
curl -X POST -H "X-Role: dispatcher" -H "Content-Type: application/json" \
  http://127.0.0.1:8090/v1/dispatch/lookup -d '{"code":"SLR-C41001","profile":"foot"}'

# Create dispatch
curl -X POST -H "X-Role: dispatcher" -H "Content-Type: application/json" \
  http://127.0.0.1:8090/v1/dispatch/assign -d '{"code":"SLR-C41001","responder":"unit-1"}'

# Record outcome
curl -X POST -H "X-Role: dispatcher" -H "Content-Type: application/json" \
  http://127.0.0.1:8090/v1/dispatch/outcome -d '{"dispatch_id":"...","outcome":"reached"}'

# Stats
curl -H "X-Role: dispatcher" http://127.0.0.1:8090/v1/dispatch/stats
```

---

## Project Structure

```
clg/el/
├── apps/
│   ├── dispatcher/          # SINGLE unified app (see below)          # Flutter app (this project)
│   │   ├── lib/
│   │   │   ├── main.dart           # App entry, role-based routing
│   │   │   ├── auth_service.dart   # Token auth (server-signed) + device_hash
│   │   │   ├── login_screen.dart   # Role selection UI
│   │   │   ├── inbound_call_screen.dart  # Calls tab (caller/dispatcher)
│   │   │   ├── dashboard_screen.dart     # Stats, recent, quick actions
│   │   │   ├── lookup_screen.dart        # Structure search + outcomes
│   │   │   ├── create_dispatch_screen.dart # Manual dispatch creation
│   │   │   ├── history_screen.dart       # Searchable dispatch log
│   │   │   ├── settings_screen.dart      # API, theme, behavior
│   │   │   ├── design_system.dart        # Colors, typography, spacing
│   │   │   ├── components.dart           # Reusable UI components
│   │   │   └── models.dart               # Data models + JSON
│   │   └── pubspec.yaml
│   └── mapper/              # Separate Flutter app (mapper role)
├── services/
│   └── registry-api/        # Node.js backend
│       ├── src/
│       │   ├── server.js           # Express routes, role middleware
│       │   ├── registry.js         # SQLite schema, structures/zones
│       │   ├── dispatch.js         # Dispatch engine, persistence
│       │   ├── grievance.js        # Triage state machine, ML
│       │   └── sync.js             # Bootstrap, tasks, outbox
│       └── test/
│           └── grievance.test.js   # Unit tests
├── docs/
│   ├── development-plan.md   # Milestones M0-M8
│   ├── M7_TRIGE_STATE_MACHINE.md
│   ├── M8_LOCAL_STATUS.md
│   ├── PRESENT_DEMO.md
│   └── RUNBOOK.md
├── scripts/
│   ├── setup-flutter.sh      # Auto-install Flutter SDK
│   └── verify-all.sh         # Full test suite
├── docker-compose.yml        # Stack: registry-api + dispatcher (optional)
└── .gitignore
```

---

## Role Permissions Matrix

| Feature | Caller | Dispatcher | Admin |
|---------|--------|------------|-------|
| Log emergency call | ✅ | ✅ | ✅ |
| View **own** calls | ✅ | — | — |
| View **all** calls | — | ✅ | ✅ |
| Dashboard stats | — | ✅ | ✅ |
| Structure lookup | — | ✅ | ✅ |
| Create dispatch | — | ✅ | ✅ |
| Record outcome | — | ✅ | ✅ |
| History (all) | — | ✅ | ✅ |
| Settings | — | ✅ | ✅ |

---

## Development

### Run Tests
```bash
# Backend
cd services/registry-api && node --test test/*.test.js

# Frontend
cd apps/dispatcher && flutter test
# → dispatcher: 2 passing, mapper: 7 passing
```

### Verify All
```bash
./scripts/verify-all.sh
# Runs: backend tests, frontend tests, API smoke tests, build checks
```

### Docker (Optional)
```bash
docker-compose up -d
# registry-api on :8090 (dispatcher is a Flutter binary/APK, not a container)
```

---

## Deployment Notes

- **Backend**: Single Node process, SQLite file (`DB_PATH`), stateless
- **Frontend**: Self-contained binaries (Linux) / signed APK (Android)
- **No external dependencies** at runtime (Flutter SDK only for build)
- **Offline-capable**: Sync endpoint bootstraps local data
- **APK Distribution**: Upload `app-release.apk` to GitHub Releases or use Actions workflow

---

## Constraints (from PRD)

1. Structure identity is never assigned by AI
2. Possible duplicates require human review — no automated merge path
3. Resident identity is a separate database with separate credentials
4. Offline operation is required; sync is opportunistic
5. AI scope limited to path-graph clustering, footprint bootstrap, change-detection prioritisation, low-literacy capture assistance
6. Dispatch operates only inside the pilot mapped zone
7. Inference never silently overwrites ground truth
8. Path-graph algorithm chosen by measurement, not assumption

Constraints 1, 2, 3, 6, 7, 8 enforced by database permissions/triggers — see `docs/architecture.md` §5.10, §5.11.

---

## License

Semester project — RVCE CSE 2026. Educational use only.

---

## Acknowledgments

- Flutter team for the framework
- Node.js / Express for the backend
- OpenStreetMap / OSM data concepts for zone/structure modeling
---

## Single unified app

There is one Flutter application: `apps/dispatcher`. It contains both the
dispatch system and the field mapper, selected by the **account role**
returned at login — not by device:

| Role | Tabs |
|---|---|
| Caller | Calls |
| Dispatcher / Admin | Calls, Dashboard, Lookup, Map, Create, History, Settings |
| Mapper | Field (offline map, GPS walk, capture, sync) |

The former standalone `apps/mapper` project was merged into it and deleted;
its offline store, GPS, sync and map code now live in `apps/dispatcher/lib/core/`,
`lib/mapper_screen.dart` and `lib/map_view.dart`.

## Offline map tiles

`scripts/download-tiles.py` downloads a small OSM tile pack for the pilot
zone (z14–17, ~5 MB) into `apps/dispatcher/tiles/`, which is bundled as an
asset. The app draws cached tiles under the vector overlay and never loads
tiles from the network. Regenerate with the script (the pack is gitignored).
