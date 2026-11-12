---
last_mapped_commit: d964f20c86bb18eb97a68714a415b6245809e1e2
last_mapped_at: 2026-11-13
---
# Codebase Structure

**Analysis Date:** 2026-11-13

## Directory Layout

```
[repo root]/
├── apps/
│   └── dispatcher/              # Flutter app (Linux desktop + Android)
│       ├── lib/                 # Dart source (flat screens + core/)
│       │   └── core/            # Offline store, sync, GPS
│       ├── test/                # Flutter tests
│       ├── android|ios|linux|macos|windows|web/   # Platform scaffolding (excluded from analysis)
│       └── pubspec.yaml
├── services/
│   ├── registry-api/            # Node.js HTTP API + domain logic (main backend)
│   │   ├── src/                 # server.js, registry.js, dispatch.js, auth.js, ...
│   │   ├── test/                # node:test suites
│   │   ├── migrations/          # Postgres/PostGIS SQL (not run by Node runtime)
│   │   ├── Dockerfile
│   │   └── package.json
│   ├── graph-service/           # Python routing sidecar
│   │   ├── src/                 # server.py, routing.py, hybrid.py
│   │   ├── test/                # pytest-style tests
│   │   └── tools/               # Offline evaluation scripts (sweep, compare)
│   ├── consent-api/             # Resident identity service (separate DB by design)
│   │   ├── src/consent.js
│   │   ├── migrations/000_init.sql
│   │   └── test/consent.test.js
│   └── change-detector/         # Imagery diff candidate producer (stub)
│       └── src/imagery_diff.js
├── packages/
│   └── sync-core/               # Dependency-free shared sync logic
│       ├── index.js
│       └── test/
├── docs/                        # ADR, architecture, API, database, runbook, plans
├── spike/                       # M0 path-graph algorithm experiments (Python + results JSON)
├── scripts/                     # Setup, verification, PostGIS and isolation tests
│   └── shims/                   # SQL shims for environments without PostGIS
├── .github/workflows/           # build-apk.yml (tag-triggered APK release)
├── .planning/codebase/          # Generated codebase maps (this file)
├── docker-compose.yml           # registry-api service only
├── prd-informal-settlement-registry.md
└── README.md
```

## Directory Purposes

**`apps/dispatcher/lib/`:**
- Purpose: All Flutter UI and app wiring. Flat layout, one file per screen.
- Contains: `main.dart` (app shell, role-based tabs), `*_screen.dart` (one per screen), `components.dart` and `design_system.dart` (shared widgets and tokens), `models.dart` (API DTOs), `auth_service.dart`, `map_view.dart`, `tile_layer.dart`.
- Key files:
  - `apps/dispatcher/lib/main.dart`: `DispatcherApp`, `_AuthGate`, `_MainShell`, `_NavItem`
  - `apps/dispatcher/lib/models.dart`: `DispatchStats`, `DispatchItem`, `LookupResult`, `RouteResult`, `AppSettings`
  - `apps/dispatcher/lib/design_system.dart`: theme tokens (spacing, typography, dark theme)

**`apps/dispatcher/lib/core/`:**
- Purpose: Non-UI infrastructure for offline operation.
- Contains: `local_store.dart` (sqflite schema and CRUD), `sync_service.dart` (push and pull), `gps_service.dart` (permission and fix).
- Key files: `apps/dispatcher/lib/core/local_store.dart` (`LocalStore`, `ServiceRecord`, `StructureType`, `ServiceType` enums at top)

**`apps/dispatcher/test/`:**
- Purpose: Flutter unit and widget tests.
- Contains: `breadcrumb_map_test.dart`, `offline_capture_test.dart`, `tile_math_test.dart`, `widget_test.dart`.

**`services/registry-api/src/`:**
- Purpose: Every server-side domain module and the HTTP entry point.
- Contains: `server.js` (router), `registry.js` (Registry class and schema), `dispatch.js`, `feedback.js`, `disclosure.js`, `grievance.js` (constants only), `auth.js`, `qr.js`.
- Key files: `services/registry-api/src/server.js`, `services/registry-api/src/registry.js`

**`services/registry-api/test/`:**
- Purpose: Node test suites. Names reflect the domain area.
- Contains: `registry.test.js`, `dispatch.test.js`, `feedback.test.js`, `disclosure.test.js`, `grievance.test.js`, `auth.test.js`, `breadcrumbs.test.js`, `feedback-http.test.js`, `http-e2e.test.js`, `postgis-registry.test.js`, `review-fixes.test.js`.
- Note: `package.json` `test` script is a placeholder. Run with `node --test services/registry-api/test/`.

**`services/registry-api/migrations/`:**
- Purpose: PostgreSQL/PostGIS DDL for the production target.
- Contains: `000_init.sql` (includes the seed zone C4 and five structures), `001_postgis_verify.sql`, `002_feedback.sql`.
- Generated: No. Committed: Yes. Applied by: `scripts/setup-postgis.sh`, `scripts/postgis-verify.sh`. The SQLite runtime uses schema from `registry.js` instead.

**`services/graph-service/src/`:**
- Purpose: Route computation.
- Contains: `server.py` (HTTP), `routing.py` (`GraphRegistry`, `route`), `hybrid.py` (hybrid graph algorithm).

**`services/graph-service/tools/`:**
- Purpose: Offline evaluation scripts, not runtime code.
- Contains: `compare_hybrid_vs_spine.py`, `sweep_seeds.py`.

**`services/consent-api/`:**
- Purpose: Resident identity vault. Designed as a separate process with its own database and credentials (C3).
- Contains: `src/consent.js` (`ConsentStore`, scopes `store_identity`, `link_to_structure`, `share_on_dispatch`, `receive_notification`), `migrations/000_init.sql`, `test/consent.test.js`.
- Not wired into `registry-api`.

**`services/change-detector/src/`:**
- Purpose: Candidate-generation helpers for imagery diff. Currently pure functions with no I/O.
- Contains: `imagery_diff.js` (4 lines of exports).

**`packages/sync-core/`:**
- Purpose: Shared merge and outbox logic, dependency-free so it can be vendored.
- Contains: `index.js` (CRDT, clock, outbox, ledger, cursor, gate), `test/constraints.test.js`, `test/offline-acceptance.test.js`.

**`docs/`:**
- Purpose: Authoritative design. Read before changing domain rules.
- Key files: `docs/architecture.md` (system design, sections 1-5), `docs/api.md` (HTTP contract), `docs/database.md`, `docs/ADR.md`, `docs/RUNBOOK.md`, `docs/M7_TRIGE_STATE_MACHINE.md` (triage state machine), `docs/M8_LOCAL_STATUS.md`, `docs/development-plan.md`, `docs/PRESENT_DEMO.md`.

**`spike/`:**
- Purpose: M0 experiments comparing path-graph algorithms. Results drive the decision recorded in `docs/architecture.md` §5.8.
- Contains: `m0_*.py` scripts, `m0_*.json` results, `M0_RESULTS.md`, `run.sh`.
- Generated: result JSON is generated by the scripts. Committed: Yes.

**`scripts/`:**
- Purpose: Environment setup and verification.
- Key files: `verify-all.sh` (full check), `registry-schema-test.sh`, `c3-isolation-test.sh` (checks structural and identity DB separation), `setup-flutter.sh`, `setup-postgis.sh`, `download-tiles.py`.

**`.github/workflows/`:**
- Purpose: CI.
- Key files: `build-apk.yml` (Flutter 3.24 release APK on `v*` tags, attaches to a GitHub Release).

**`.planning/`:**
- Purpose: GSD planning and codebase analysis output. `codebase/` holds these documents.
- Generated: Yes. Committed: decided by the project's GSD configuration.

## Key File Locations

**Entry Points:**
- `services/registry-api/src/server.js`: HTTP API (`node services/registry-api/src/server.js`, port `PORT` default 8090)
- `services/graph-service/src/server.py`: routing sidecar (port `PORT` default 8092)
- `apps/dispatcher/lib/main.dart`: Flutter app entry (`void main()`)

**Configuration:**
- `services/registry-api/src/auth.js`: demo users (`DEFAULT_USERS`), token secret (`AUTH_SECRET` env var, `DEV_SECRET` fallback)
- `docker-compose.yml`: `registry-api` container, `DB_PATH=/data/registry.db`, volume `./data:/data`
- `apps/dispatcher/analysis_options.yaml`: Dart lint configuration
- `apps/dispatcher/pubspec.yaml`: Flutter dependencies (`provider`, `sqflite`, `sqflite_common_ffi`, `geolocator`, `http`, `shared_preferences`, `google_fonts`, `url_launcher`, `uuid`, `crypto`, `path_provider`)
- `.gitignore`, `apps/dispatcher/.gitignore`, `apps/dispatcher/.metadata`
- Environment variables read in code: `PORT`, `DB_PATH`, `GRAPH_URL`, `DISPATCH_BACKEND`, `AUTH_SECRET`

**Core Logic:**
- `services/registry-api/src/registry.js`: all structure, sync, dedup and breadcrumb rules
- `services/registry-api/src/dispatch.js`: dispatch backend contract and internal implementation
- `services/registry-api/src/feedback.js`: evidence promotion
- `services/registry-api/src/disclosure.js`: role-based read disclosure
- `packages/sync-core/index.js`: merge and outbox rules
- `apps/dispatcher/lib/core/local_store.dart`: offline database
- `apps/dispatcher/lib/core/sync_service.dart`: client sync

**Testing:**
- `services/registry-api/test/`: Node test suites
- `packages/sync-core/test/`: constraint and offline acceptance tests
- `services/graph-service/test/`: Python routing tests
- `apps/dispatcher/test/`: Flutter tests

## Naming Conventions

**Files:**
- Dart: `snake_case.dart`, screens suffixed `_screen.dart` (`lookup_screen.dart`, `create_dispatch_screen.dart`), services suffixed `_service.dart` (`auth_service.dart`, `gps_service.dart`, `sync_service.dart`)
- JavaScript: `kebab-case` for multi-word test files (`feedback-http.test.js`, `review-fixes.test.js`), `camelCase`-ish single words for modules (`registry.js`, `dispatch.js`, `disclosure.js`). Module filenames are lowercase single words.
- Python: `snake_case.py` (`routing.py`, `hybrid.py`, `compare_hybrid_vs_spine.py`)
- SQL migrations: `NNN_description.sql` with three-digit prefix (`000_init.sql`, `001_postgis_verify.sql`, `002_feedback.sql`)
- Spike scripts: `m0_<topic>.py` and matching `m0_<topic>.json` results

**Directories:**
- Service folders: lowercase kebab-case under `services/` (`registry-api`, `graph-service`, `consent-api`, `change-detector`)
- Shared packages: `packages/<name>` kebab-case (`sync-core`)
- Flutter: `apps/dispatcher` (single app)

**Identifiers in code:**
- Routes: `/v1/<resource>[/:id][/<action>]`, e.g. `/v1/dedup/:id/decision`, `/v1/grievances/:id/triage`
- Structure codes: zone prefix plus number (e.g. zone `C4`, codes issued by `Registry.issueCode()` in `registry.js` line 322)
- Milestone tags in comments: `M0`–`M8`, `C1`–`C9` constraints, `PRD n.n` references. Keep these when editing since they link code to the decision records.

## Where to Add New Code

**New HTTP endpoint:**
- Route branch: `services/registry-api/src/server.js`, placed inside the `try` block in the matching section (`// ---- sync`, `// ---- dispatch`, etc.). Add a new section comment if the domain is new.
- Domain logic: add a method to `Registry` in `services/registry-api/src/registry.js`, or a new module in `services/registry-api/src/` that is required from `server.js` (follow `feedback.js` / `disclosure.js`).
- Auth: call `requireRole('dispatcher', ...)` at the top of the branch. Never read role from headers.
- Tests: `services/registry-api/test/<domain>.test.js` for domain logic, `services/registry-api/test/http-e2e.test.js` or `feedback-http.test.js` pattern for HTTP.

**New dispatch backend:**
- Implementation: `services/registry-api/src/dispatch.js`, extend `DispatchBackend` and add a `case` to `createBackend()`.
- Tests: `services/registry-api/test/dispatch.test.js`.

**New database table or column (SQLite runtime):**
- Schema: `applySchema()` in `services/registry-api/src/registry.js` (line 78).
- Mirror in production schema: `services/registry-api/migrations/` as a new numbered file.
- Local client table: `apps/dispatcher/lib/core/local_store.dart` (table creation in the `onCreate` block, lines ~147-225).

**New Flutter screen:**
- Implementation: `apps/dispatcher/lib/<name>_screen.dart`
- Register in: `apps/dispatcher/lib/main.dart` (import, `_NavItem` list in `_MainShellState`, role visibility check)
- Shared widgets go to `apps/dispatcher/lib/components.dart`; tokens and theme go to `apps/dispatcher/lib/design_system.dart`.
- Tests: `apps/dispatcher/test/`

**New client sync op type:**
- Enqueue: `apps/dispatcher/lib/core/local_store.dart` (`pending_op` insert)
- Push: `apps/dispatcher/lib/core/sync_service.dart`
- Apply on server: `Registry.push()` in `services/registry-api/src/registry.js` (line 625). Add a table branch and a receipt.
- Shared merge rules: `packages/sync-core/index.js` (`CRDT_FIELDS_BY_TABLE`) if the field is CRDT-merged.

**New shared utility (Node):**
- Put it in the module that owns the domain. Use `packages/sync-core` only for code that must run identically in the mobile client, tests and sync.

**New graph routing behaviour:**
- `services/graph-service/src/routing.py` or `hybrid.py`. Evaluation scripts go to `services/graph-service/tools/`. Keep the approved-algorithm guard (`serves_routes`) intact.

**New Flutter model (DTO):**
- `apps/dispatcher/lib/models.dart`

**New script:**
- `scripts/<name>.sh` and add to `scripts/verify-all.sh` if it should run in CI or the verify pass.

## Special Directories

**`apps/dispatcher/android`, `ios`, `linux`, `macos`, `windows`, `web`:**
- Purpose: Flutter platform runners and build configuration.
- Generated: Yes (by `flutter create`). Committed: Yes. Excluded from this analysis.

**`apps/dispatcher/build/` (not in repo, produced by build):**
- Purpose: Build output for `flutter build linux` and `flutter build apk`.
- Generated: Yes. Committed: No (see `.gitignore`).

**`services/registry-api/node_modules/` (not in repo):**
- Purpose: npm dependencies. Only `qrcode` is declared.
- Generated: Yes. Committed: No.

**`data/` (referenced by `docker-compose.yml`, volume `./data:/data`):**
- Purpose: SQLite database directory for the containerised API.
- Generated: Yes. Committed: No.

**`.planning/codebase/`:**
- Purpose: Output of codebase mapping.
- Generated: Yes.

---

*Structure analysis: 2026-11-13*
