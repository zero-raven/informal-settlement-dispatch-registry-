---
last_mapped_commit: d964f20c86bb18eb97a68714a415b6245809e1e2
last_mapped_at: 2026-11-13
---
# Technology Stack

**Analysis Date:** 2026-11-13

## Languages

**Primary:**
- JavaScript (CommonJS, `'use strict'`) - Backend services and shared logic: `services/registry-api/src/*.js`, `services/consent-api/src/consent.js`, `services/change-detector/src/imagery_diff.js`, `packages/sync-core/index.js`
- Dart 3.x (`sdk: ^3.5.4`) - Flutter dispatcher/mapper app: `apps/dispatcher/lib/**/*.dart`

**Secondary:**
- Python 3 - Graph routing service and spike/research tooling: `services/graph-service/src/*.py`, `services/graph-service/tools/*.py`, `spike/*.py`, `scripts/download-tiles.py`
- SQL (PostgreSQL/PostGIS dialect and SQLite) - Schema and migrations: `services/registry-api/migrations/000_init.sql`, `001_postgis_verify.sql`, `002_feedback.sql`, `services/consent-api/migrations/000_init.sql`
- Bash - Verification and setup scripts: `scripts/verify-all.sh`, `scripts/setup-postgis.sh`, `scripts/setup-flutter.sh`, `scripts/postgis-verify.sh`, `scripts/registry-schema-test.sh`, `scripts/c3-isolation-test.sh`, `spike/run.sh`
- YAML - CI and compose: `.github/workflows/build-apk.yml`, `docker-compose.yml`

## Runtime

**Node.js (backend):**
- Required: Node 22.13+ (or 23.4+) because `services/registry-api/src/registry.js` uses the built-in `node:sqlite` module (`DatabaseSync`) without a flag on those releases. Earlier Node 22.x needs `--experimental-sqlite`.
- Note: `README.md` states "Node.js 18+", which is out of date for the `node:sqlite` requirement.
- Uses global `fetch` (`services/registry-api/src/server.js`), so Node 18+ is the floor for that alone.
- Docker image: `node:22-alpine` (`services/registry-api/Dockerfile`).

**Python:**
- Version not pinned. No `requirements.txt`, `pyproject.toml`, or lockfile found.
- Virtualenv expected at `.venv-spike/` (referenced by `scripts/verify-all.sh` and `spike/run.sh`).
- Runtime deps used: `numpy`, `scipy` (`scipy.sparse`, `scipy.sparse.csgraph`, `scipy.spatial`), `scikit-learn` (installed by `spike/run.sh`), `pytest` for tests.
- Installed via `uv pip install` in `spike/run.sh`.

**Flutter/Dart:**
- Flutter `3.24` stable in CI (`.github/workflows/build-apk.yml`, `subosito/flutter-action@v2`).
- Dart SDK constraint `^3.5.4` (`apps/dispatcher/pubspec.yaml`).
- Installed locally via `scripts/setup-flutter.sh` into `.cache/flutter`.

**Package Manager:**
- npm - `services/registry-api/package-lock.json` present (lockfile: present). `packages/sync-core` and `services/consent-api` have no `package.json` and are dependency-free.
- pub (Dart) - `apps/dispatcher/pubspec.lock` present (lockfile: present).
- pip / uv - no lockfile (lockfile: missing).

## Frameworks

**Core:**
- Node built-in `http` server, no web framework. Routing is hand-written in `services/registry-api/src/server.js` (`http.createServer`). The docs (`docs/architecture.md`) mention Fastify as an option, but Fastify is not a dependency.
- Python `http.server` (`BaseHTTPRequestHandler`) for the graph service: `services/graph-service/src/server.py`.
- Flutter (Material) for the mobile/desktop UI: `apps/dispatcher/lib/main.dart`, `apps/dispatcher/lib/design_system.dart`.
- Flutter `provider` 6.x for state management (`package:provider` imported in 12 files).

**Testing:**
- Node built-in test runner `node:test` with `node:assert`. Run via `node --test test/*.test.js` in `packages/sync-core`, `services/registry-api`, and `services/consent-api`. The `test` script in `services/registry-api/package.json` is a placeholder that exits 1.
- `pytest` for `services/graph-service/test/test_hybrid.py` and `test_e2e_dispatch.py`.
- `flutter_test` for `apps/dispatcher/test/*.dart` (`breadcrumb_map_test.dart`, `offline_capture_test.dart`, `tile_math_test.dart`, `widget_test.dart`).
- Real PostgreSQL + PostGIS for `services/registry-api/test/postgis-registry.test.js` (uses `psql` through `child_process.execFileSync`; `PGBIN` defaults to `/usr/lib/postgresql/18/bin`).

**Build/Dev:**
- `flutter build linux --release` and `flutter build apk --release` (CI: `.github/workflows/build-apk.yml`).
- Android SDK platform 34, build-tools 34.0.0, NDK r26c (CI).
- Java 17 for local APK builds (`README.md`).
- `flutter_lints` ^4.0.0 with `apps/dispatcher/analysis_options.yaml`.
- Docker / docker-compose for the registry API only (`docker-compose.yml`).

## Key Dependencies

**Critical (Node, `services/registry-api/package.json`):**
- `qrcode` ^1.5.4 - Generates QR codes for structure codes, SVG output with SHA-256 hash (`services/registry-api/src/qr.js`).

**Critical (Node, built-in, no npm install):**
- `node:sqlite` - Runtime database for the registry (`services/registry-api/src/registry.js`).
- `node:crypto` - scrypt password hashing and HMAC-SHA256 bearer tokens (`services/registry-api/src/auth.js`, `services/consent-api/src/consent.js`).

**Critical (Dart, `apps/dispatcher/pubspec.yaml`):**
- `http` ^1.6.0 - All REST calls to the registry API and graph service (46 call sites across `apps/dispatcher/lib/`).
- `sqflite` ^2.4.1 and `sqflite_common_ffi` ^2.3.4+4 - Local offline SQLite store, FFI on desktop (`apps/dispatcher/lib/core/local_store.dart`).
- `geolocator` ^9.0.2 - GPS breadcrumb recording for the mapper (`apps/dispatcher/lib/core/gps_service.dart`). `dependency_overrides` pins `geolocator_android` to 4.2.0.
- `shared_preferences` ^2.3.0 - Persists auth token, role, device hash, and API URLs (`apps/dispatcher/lib/auth_service.dart`, `settings_screen.dart`).
- `crypto` ^3.0.3 - Hashing in the Dart client.
- `uuid` ^3.0.7 - Client-side IDs for offline operations.
- `google_fonts` ^6.2.1 - Inter font (per `README.md`). Fetches fonts at runtime unless bundled.
- `url_launcher` ^6.3.0 - External link/dialer launching.
- `path` ^1.9.0, `path_provider` ^2.1.5 - File-system paths for the local DB.
- `provider` ^6.1.2 - State management.
- `cupertino_icons` ^1.0.8 - Icon font.

**Critical (Python):**
- `numpy`, `scipy`, `scikit-learn` - Graph construction and routing for the hybrid path graph (`services/graph-service/src/hybrid.py`, `routing.py`) and spike algorithms (`spike/m0_algorithms.py`).

**Infrastructure:**
- PostgreSQL 16 + PostGIS 3.4 is the documented target for `registry_db` and `identity_db` (`docs/database.md`). Verified against PostGIS 3.6 with GEOS 3.15.0 per `docs/database.md`. Driven from the test suite through `psql`, not a Node driver. No `pg` package in `package.json`.
- `scripts/setup-postgis.sh` installs PostGIS into an unprivileged `.pgroot` prefix.

## Assets

- `apps/dispatcher/tiles/` - Bundled offline map tiles, declared in `apps/dispatcher/pubspec.yaml` under `flutter.assets`.
- `scripts/download-tiles.py` - Downloads an OSM tile pack from `https://tile.openstreetmap.org/` to populate that folder. The runtime map does not fetch network tiles (`README.md`).

## Configuration

**Environment variables (names only):**
- `PORT` - Listen port. Registry API default `8090`, graph service default `8092`.
- `DB_PATH` - SQLite file path for the registry. Defaults to `:memory:` in code and `/data/registry.db` in Docker (`docker-compose.yml`, `services/registry-api/Dockerfile`).
- `DISPATCH_BACKEND` - Selects the dispatch backend adapter. Defaults to `internal` (`services/registry-api/src/server.js`).
- `GRAPH_URL` - Base URL of the graph service. When unset, routing returns `route: null` (`services/registry-api/src/server.js`).
- `AUTH_SECRET` - HMAC signing secret. Required in production; the code throws if unset when not in dev (`services/registry-api/src/auth.js`).
- `AUTH_USERS_JSON` - JSON array of user accounts with scrypt-hashed passwords at boot (`services/registry-api/src/auth.js`).
- `ALLOW_ROLE_HEADER` - Set to `0` to disable the `X-Role` test fallback (`services/registry-api/src/auth.js`).
- `NODE_ENV` - Referenced by the auth module.
- `PGBIN` - PostgreSQL binary directory for the PostGIS test (`services/registry-api/test/postgis-registry.test.js`).

**Env file:** `.env` files are not used in the code paths reviewed. Not detected. No `.env` file was read.

**Build/config files:**
- `apps/dispatcher/pubspec.yaml`, `apps/dispatcher/analysis_options.yaml`, `apps/dispatcher/.metadata`
- `services/registry-api/package.json`, `services/registry-api/Dockerfile`
- `docker-compose.yml`
- `.github/workflows/build-apk.yml`
- `scripts/verify-all.sh` - Full local verification (node tests, pytest, flutter test, PostGIS checks).

**Hardcoded endpoints in the Flutter client:**
- Default API base `http://127.0.0.1:8090` and graph `http://127.0.0.1:8092` in `apps/dispatcher/lib/main.dart`, `models.dart`, and `settings_screen.dart`.
- A LAN address `http://192.168.1.5:8090` is hardcoded in `apps/dispatcher/lib/login_screen.dart` and `mapper_screen.dart`. Treat it as a development value.

## Platform Requirements

**Development:**
- Node 22.13+ with `node:sqlite` support.
- Flutter 3.24+ stable, Dart `^3.5.4`.
- Android SDK 34 and Java 17 for APK builds.
- GTK3 headers for Linux desktop builds (`README.md`; CI installs them in `build-apk.yml`).
- Python 3 with numpy, scipy, scikit-learn, pytest in `.venv-spike/` for graph tests.
- PostgreSQL 16+ with PostGIS for the spatial verification path (optional for most tests).

**Production / Deployment:**
- Registry API: Docker image `node:22-alpine` running `node src/server.js` on port 8090, SQLite file mounted at `/data` (`docker-compose.yml`).
- Dispatcher: Android APK and Linux desktop binary published as GitHub Release assets on `v*` tags (`.github/workflows/build-apk.yml`).
- Graph service: no Dockerfile. Run directly with Python (`services/graph-service/src/server.py`).
- Consent API and change-detector: no deployment artifacts found.

---

*Stack analysis: 2026-11-13*
