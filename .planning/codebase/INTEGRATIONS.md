---
last_mapped_commit: d964f20c86bb18eb97a68714a415b6245809e1e2
last_mapped_at: 2026-11-13
---
# External Integrations

**Analysis Date:** 2026-11-13

## APIs & External Services

**Internal HTTP services (the only runtime network dependencies in code):**
- Registry API (Node, port 8090) - Primary REST backend for the dispatcher and mapper apps.
  - Server: `services/registry-api/src/server.js`
  - Client: Dart `package:http` calls in `apps/dispatcher/lib/` (e.g. `dashboard_screen.dart`, `lookup_screen.dart`, `create_dispatch_screen.dart`, `map_screen.dart`, `mapper_screen.dart`, `inbound_call_screen.dart`, `history_screen.dart`, `admin_screen.dart`, `login_screen.dart`)
  - Auth: `Authorization: Bearer <token>` issued by `POST /v1/auth/login` (`services/registry-api/src/auth.js`)
- Graph service (Python, port 8092) - Foot/vehicle routing over the inferred path graph.
  - Server: `services/graph-service/src/server.py`
  - Called from the registry API when `GRAPH_URL` is set: `POST {GRAPH_URL}/v1/graph/route` (`services/registry-api/src/server.js`)
  - Called directly by the Flutter client: `apps/dispatcher/lib/models.dart`, `settings_screen.dart`, `main.dart`
  - Auth: none. Responses are CORS `*`. The service holds no DB credentials (`services/graph-service/src/server.py` header comment).
  - Failure behavior: the registry returns `route: null` and never fabricates a path.

**Public tile server (build-time only):**
- OpenStreetMap tile server - `https://tile.openstreetmap.org/`
  - Used only by `scripts/download-tiles.py` to pre-fetch a pilot tile pack into `apps/dispatcher/tiles/`.
  - The app draws offline. No runtime tile requests (`README.md`, `apps/dispatcher/lib/tile_layer.dart`).
  - Auth: none (public tile endpoint).

**Tooling downloads (setup only):**
- Flutter SDK - `https://storage.googleapis.com/flutter_infra_release/...` in `scripts/setup-flutter.sh`
- uv installer - `https://astral.sh/uv/install.sh` in `spike/run.sh`
- PostGIS Arch package - downloaded by `scripts/setup-postgis.sh`

**QR generation:**
- `qrcode` npm package generates structure QR codes locally (`services/registry-api/src/qr.js`). No external QR service.

## Data Storage

**Registry database (primary):**
- SQLite via Node built-in `node:sqlite` (`DatabaseSync`), file path from `DB_PATH` (`services/registry-api/src/registry.js`).
- Schema: `services/registry-api/migrations/000_init.sql` (documented as PostgreSQL + PostGIS), `002_feedback.sql`.
- The runtime SQLite DB starts empty. Seed data (Zone C4 and 5 structures) lives only in the Postgres migration (`README.md`).
- Docker volume: `./data:/data` (`docker-compose.yml`).

**PostgreSQL + PostGIS (documented target, verification path):**
- `registry_db`: PostgreSQL 16 + PostGIS 3.4. Structures, services, grievances, verification events, path-graph topology, mappers. Not encrypted-separate. (`docs/database.md`)
- Exercised by `services/registry-api/test/postgis-registry.test.js` through `psql` (no Node driver). Connection via `PGBIN` and a local unix socket on the `postgres` user.
- Migration `services/registry-api/migrations/001_postgis_verify.sql` must run against a real PostGIS instance.
- Not wired into the running server. `DISPATCH_BACKEND` selects only the `internal` adapter by default (`services/registry-api/src/server.js`).

**Identity database (separate, planned isolation):**
- `identity_db`: PostgreSQL 16, separate instance and separate credentials (`docs/database.md`). Holds consent vault, resident identity, linkage. Marked as encrypted at rest in the docs.
- Implemented in code only as an in-process module: `services/consent-api/src/consent.js` and `services/consent-api/migrations/000_init.sql`. No DB client, no network listener. Not deployed.

**Local device storage (mapper and dispatcher):**
- `sqflite` / `sqflite_common_ffi` SQLite file in the app documents directory (`apps/dispatcher/lib/core/local_store.dart`). Offline outbox for breadcrumbs, structures, and sync ops.
- `shared_preferences` for auth token, role, device hash, user name, and configured API URLs (`apps/dispatcher/lib/auth_service.dart`, `settings_screen.dart`).

**File Storage:**
- Local filesystem only. Map tiles bundled as Flutter assets (`apps/dispatcher/pubspec.yaml`, `tiles/`).

**Caching:**
- None detected. The graph service keeps versioned in-memory graphs (`services/graph-service/src/routing.py`, `GraphRegistry`).

## Authentication & Identity

**Auth Provider:**
- Custom. No third-party identity provider (no OAuth, Firebase, Auth0, Supabase, or similar found).
  - Implementation: `services/registry-api/src/auth.js`
  - Passwords: `crypto.scryptSync` with per-user salt, 32-byte key. Users loaded from the `AUTH_USERS_JSON` env var at boot. Demo accounts are documented in that file and must not be used in production.
  - Tokens: HMAC-SHA256 signed bearer tokens. Secret from `AUTH_SECRET`. A development default secret exists and is flagged; the code throws if `AUTH_SECRET` is missing in production.
  - Role is checked server-side from the verified token.
  - Test-only fallback: `X-Role` header, enabled only when the dev secret is in use and `ALLOW_ROLE_HEADER` is not `0`.
- Consent model: `services/consent-api/src/consent.js` defines four opt-in scopes (PRD section 6.3). Not deployed.
- Device identity: the Flutter app generates and stores a `device_hash` in `shared_preferences` (`apps/dispatcher/lib/auth_service.dart`). Used as the caller identifier on `POST /v1/grievances` (`README.md`).

## Monitoring & Observability

**Error Tracking:**
- None detected (no Sentry, Crashlytics, or similar in `apps/dispatcher/pubspec.yaml` or Node manifests).

**Logs:**
- `console` output. Server prints `registry-api listening on :<port>`. No structured logging library.

## CI/CD & Deployment

**Hosting:**
- Registry API: self-hosted Docker container (`services/registry-api/Dockerfile`, `docker-compose.yml`). No cloud provider config found.
- Dispatcher app: distributed as GitHub Release assets (APK and Linux binary).

**CI Pipeline:**
- GitHub Actions: `.github/workflows/build-apk.yml`
  - Triggers on tags `v*`.
  - Builds Android release APK (`flutter build apk --release`) and Linux release binary (`flutter build linux --release`).
  - Publishes with `softprops/action-gh-release@v2` using the built-in `GITHUB_TOKEN`.
  - Uses `actions/checkout@v4`, `subosito/flutter-action@v2`, `android-actions/setup-android@v3`.
- No CI job runs the Node, Python, or Flutter tests. Tests run only through `scripts/verify-all.sh` locally.

## Environment Configuration

**Required env vars (names only):**
- `AUTH_SECRET` - Required in production for the registry API.
- `AUTH_USERS_JSON` - Required for real user accounts. Without it, login returns no user.
- `DB_PATH` - SQLite file location. Default `:memory:` in code, `/data/registry.db` in Docker.
- `PORT` - Listener port (8090 for registry, 8092 for graph).

**Optional env vars:**
- `GRAPH_URL` - Enables graph routing.
- `DISPATCH_BACKEND` - Backend adapter name, default `internal`.
- `ALLOW_ROLE_HEADER` - Set to `0` to disable the test-only role header.
- `PGBIN` - PostgreSQL bin directory for the PostGIS test only.

**Client-side configuration:**
- Registry and graph base URLs are set in-app under Settings and persisted in `shared_preferences` (`apps/dispatcher/lib/settings_screen.dart`). Defaults are localhost; see STACK.md for hardcoded LAN addresses.

**Secrets location:**
- Environment variables supplied at process start. No secrets manager, vault, or secrets file in the repo was detected. `.env` files are not used in the reviewed code. Not detected. No secret files were read.
- GitHub Actions uses `secrets.GITHUB_TOKEN` only.

## Webhooks & Callbacks

**Incoming:**
- None. The registry API exposes REST endpoints only (`README.md`, `services/registry-api/src/server.js`). No webhook receivers found.

**Outgoing:**
- None. The only outbound HTTP from the backend is the optional `GRAPH_URL` call (`services/registry-api/src/server.js`).

## Integrations Not Present

- No payment, SMS, email, push-notification, or mapping SDK (Google Maps, Mapbox) found in manifests or source.
- No message queue, cache server (Redis), or object storage client.
- Imagery: `services/change-detector/src/imagery_diff.js` produces candidate records and explicit coverage-gap reports. It makes no network calls. The docs mention a free imagery source, but no client for it exists in code.

---

*Integration audit: 2026-11-13*
