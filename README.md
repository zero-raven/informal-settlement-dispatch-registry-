# Informal Settlement Registry & Emergency Dispatch

A living, offline-first registry for un-addressed dwellings that feeds emergency dispatch. Mappers walk and pin structures offline. Each structure gets a stable code. Dispatchers look up a code and get a location plus a walking route. A failed dispatch or a resident complaint triggers re-verification, so the registry stays current without a manual resurvey.

Semester project (RVCE CSE 2026). The pilot uses a college campus as a stand-in for a settlement. The product requirements are in [`.planning/codebase/prd-informal-settlement-registry.md`](.planning/codebase/prd-informal-settlement-registry.md), and decisions that differ from them are in [`.planning/codebase/ADR.md`](.planning/codebase/ADR.md).

---

## What's in the repo

| Path | What it is | Stack |
|---|---|---|
| `services/registry-api/` | Structural registry: sync, dedup review, code issuance, dispatch, grievances, auth. HTTP on **:8090** | Node ≥ 22.13, built-in `node:sqlite`, no framework |
| `services/graph-service/` | Builds a walkable path graph from mapper GPS breadcrumbs and serves routes. HTTP on **:8092** | Python 3.12+, numpy / scipy / scikit-learn |
| `services/consent-api/` | Consent vault: resident identity, stored separately and opt-in (library + tests) | Node |
| `services/change-detector/` | Imagery-diff candidates (stub) | Node |
| `packages/sync-core/` | Shared offline-sync / field-merge rules, mirrored by the registry | Node |
| `apps/dispatcher/` | **The one Flutter app.** The role from login picks the UI: caller, dispatcher, admin or mapper | Flutter 3.24, Dart ≥ 3.5 |
| `spike/` | M0 path-graph algorithm study, with the measurements behind ADR-001 | Python |
| `config/zones.campus.json` | Dispatch zones loaded at startup | JSON |
| `scripts/` | `demo.sh` (run the demo), `verify-all.sh` (every check), setup helpers | Bash |
| `docs/` | Architecture, API, database, demo runbook, milestone notes | Markdown |

```
mapper app ──sync──▶ registry-api ◀──lookup── dispatcher app
                       │    ▲
           breadcrumbs │    │ route (GRAPH_URL)
                       ▼    │
                    graph-service
```

---

## Setup

You need **Node 22.13+** (CI uses 24), **Python 3.12+**, and **Flutter 3.24** (only for the app). On Windows, use Git Bash for the `scripts/*.sh` files.

```bash
git clone https://github.com/zero-raven/informal-settlement-dispatch-registry-.git
cd informal-settlement-dispatch-registry-

# Node dependencies (registry-api)
npm ci --prefix services/registry-api

# Python venv for the graph service and spike
python -m venv .venv
.venv/bin/pip install -r services/graph-service/requirements.txt          # macOS / Linux
# .venv/Scripts/pip install -r services/graph-service/requirements.txt    # Windows

# Flutter app dependencies
cd apps/dispatcher && flutter pub get && cd ../..
```

No Flutter installed? `scripts/setup-flutter.sh` installs a repo-local SDK into `.cache/flutter` (Linux).

Then check everything works:

```bash
bash scripts/verify-all.sh
```

Sections whose tools are missing (Postgres, PostGIS, Flutter) are **skipped, not failed**.

---

## Run it

### Everything at once (recommended)

```bash
bash scripts/demo.sh start      # registry :8090 + graph service :8092, data in ./demo.db
bash scripts/demo.sh rebuild    # build the walk graph from synced breadcrumbs
bash scripts/demo.sh stop
```

`bash scripts/demo.sh selftest` runs the whole loop (sync → code → lookup → route → failed outcome → re-survey task) against throwaway in-memory servers. Run it before any demo. The live click-path is in [`docs/PRESENT_DEMO.md`](docs/PRESENT_DEMO.md).

### Each service by hand

```bash
# registry-api
cd services/registry-api
DB_PATH=./registry.db ZONES_FILE=../../config/zones.campus.json GRAPH_URL=http://127.0.0.1:8092 npm start

# graph-service (another terminal, repo root)
REGISTRY_URL=http://127.0.0.1:8090 .venv/bin/python services/graph-service/src/server.py

# app (another terminal)
cd apps/dispatcher && flutter run          # pick a device; desktop: flutter run -d linux
```

In the app, open Settings and set **Registry API Base URL** to `http://<your laptop's LAN IP>:8090` when you run it on a phone. Set **Responder start latitude/longitude** to where responders set off from.

### Configuration

| Variable | Service | Default | Meaning |
|---|---|---|---|
| `PORT` | registry / graph | `8090` / `8092` | Listen port |
| `DB_PATH` | registry | `:memory:` | SQLite file. **The default keeps nothing after a restart**; set a file path to keep data |
| `ZONES_FILE` | registry | unset | JSON array of dispatch zones. Unset means every lookup returns `outside_mapped_zone`. A missing, empty or invalid file stops the server at startup |
| `GRAPH_URL` | registry | unset | Graph service base URL. Unset means lookups return `route: null` |
| `DISPATCH_BACKEND` | registry | `internal` | Dispatch backend adapter |
| `AUTH_SECRET` | registry | dev secret | Token signing secret. **Required when `NODE_ENV=production`** |
| `AUTH_USERS_JSON` | registry | demo users | JSON `[{username,password,role}]` that replaces the demo accounts |
| `ALLOW_ROLE_HEADER` | registry | allowed with the dev secret | `0` disables the dev-only `X-Role` header fallback |
| `REGISTRY_URL` | graph | unset | Registry to pull breadcrumbs from for `{"source":"registry"}` rebuilds |

**Demo accounts** (dev secret only, from `services/registry-api/src/auth.js`): `caller/caller123`, `dispatcher/dispatch123`, `mapper/mapper123`, `reviewer/review123`, `admin/admin123`. Set `AUTH_SECRET` and `AUTH_USERS_JSON` for anything that isn't a local demo.

Docker: `docker compose up` runs the registry only, with `config/` mounted. Run the graph service on the host for routes.

---

## Test

| What | Command |
|---|---|
| Everything available on this machine | `bash scripts/verify-all.sh` |
| registry-api | `npm test --prefix services/registry-api` |
| All Node packages | `node --test packages/sync-core/test/*.test.js services/registry-api/test/*.test.js services/consent-api/test/*.test.js` |
| graph-service (incl. cross-service E2E) | `.venv/bin/python -m pytest services/graph-service/test -q` |
| Flutter app | `cd apps/dispatcher && flutter analyze && flutter test` |
| Demo loop end-to-end | `bash scripts/demo.sh selftest` |

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs the Node, Python, demo-loop and Flutter checks on every push to `main` and on every PR. Pushing a `v*` tag builds the APK and a Linux binary and attaches them to a GitHub Release ([`build-apk.yml`](.github/workflows/build-apk.yml)).

The PostGIS and Postgres schema checks (`scripts/postgis-verify.sh`, `registry-schema-test.sh`, `c3-isolation-test.sh`) need a local Postgres; `scripts/setup-postgis.sh` sets one up (Linux).

---

## The app

One Flutter app, `apps/dispatcher`. The **account role returned at login** decides which tabs you see:

| Role | Tabs |
|---|---|
| Caller | Calls, More |
| Dispatcher / Admin | Home, Calls, Lookup, Map, Admin, More |
| Mapper | Field (offline map, GPS walk, capture, sync), More |

Mapper capture is fully offline: structures, services and GPS points go to local SQLite and an outbox. They sync to `POST /v1/sync/push` whenever a registry is reachable. A synced structure shows its code; a possible duplicate shows none until a reviewer decides.

**Offline map tiles** (optional): `python scripts/download-tiles.py --out apps/dispatcher/tiles` downloads a small OSM pack (z14–17) for the pilot area, and it is bundled as an asset. The pack is gitignored. Without it, the app draws only the vector layer.

**Build:** `flutter build apk` (Android) or `flutter build linux` (needs GTK3: `apt install libgtk-3-dev` / `pacman -S gtk3`).

---

## API at a glance

The full reference is in [`docs/api.md`](docs/api.md). Get a token, then call:

```bash
TOKEN=$(curl -s -X POST http://127.0.0.1:8090/v1/auth/login \
  -H 'Content-Type: application/json' -d '{"username":"dispatcher","password":"dispatch123"}' \
  | node -pe 'JSON.parse(require("fs").readFileSync(0)).token')

curl -s -X POST http://127.0.0.1:8090/v1/dispatch/lookup \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"code":"SLR-C41001","profile":"foot","responder_location":{"lat":12.97,"lon":77.59}}'
```

| Area | Endpoints |
|---|---|
| Auth | `POST /v1/auth/login`, `POST /v1/auth/refresh`, `GET /v1/auth/me` |
| Sync | `POST /v1/sync/push`, `GET /v1/sync/pull`, `GET /v1/sync/bootstrap`, `GET /v1/sync/health`, `GET /v1/breadcrumbs` |
| Structures | `GET /v1/structures`, `GET /v1/structures/:code`, `GET /v1/structures/:code/qr`, `GET /v1/structures/:code/services`, `GET /v1/zones/:zone/service-stats` |
| Dedup review | `GET /v1/dedup`, `POST /v1/dedup/:id/decision` |
| Dispatch | `POST /v1/dispatch/lookup`, `/assign`, `/outcome`; `GET /v1/dispatch/stats`, `/recent`, `/capabilities` |
| Feedback | `GET /v1/tasks`, `POST /v1/tasks/:id/complete`, `GET /v1/assertions/candidates`, `POST /v1/assertions/:id/verify` |
| Grievances | `POST /v1/grievances`, `GET /v1/grievances`, `POST /v1/grievances/:id/triage` |
| Admin | `GET /v1/admin/users`, `DELETE /v1/admin/structures/:id` (soft delete), `GET /v1/zones` |
| Graph (:8092) | `GET /v1/graph/health`, `GET /v1/graph/segments`, `POST /v1/graph/route`, `POST /v1/graph/rebuild` |

---

## Debugging

| Symptom | Likely cause |
|---|---|
| Lookup returns `outside_mapped_zone` | `ZONES_FILE` unset, or the structure is outside every zone radius. Check `GET /v1/zones` |
| Lookup returns `code_not_finalized` | The structure is waiting in dedup review (a pin within ~12 m of another). Decide it via `/v1/dedup` |
| Lookup works but `route: null` | `GRAPH_URL` unset, graph not built (`demo.sh rebuild`), or the start/destination is more than 25 m from any walked path |
| Rebuild returns `insufficient_breadcrumbs` | Fewer than 12 GPS points synced. Check the app's sync count |
| Data vanished after restart | `DB_PATH` was left at `:memory:` |
| Phone can't reach the registry | Use the laptop's LAN IP, not `127.0.0.1`. Same network, and the firewall allows :8090 |
| Graph E2E test says "port already serving" | A leftover graph or registry process holds :8095/:8096. Stop it |

Service logs go to stdout. `demo.sh start` writes them to `.demo.pids.registry.log` and `.demo.pids.graph.log`.

---

## Design rules the code enforces

1. Structure identity is never assigned by AI. A code is issued by a human dedup decision, or automatically at sync when no duplicate candidate is nearby (C1).
2. Possible duplicates require human review. There is no automated merge path (C2).
3. Resident identity lives in a separate store with separate credentials (C3).
4. Offline operation is required; sync is opportunistic.
5. Dispatch works only inside an enabled zone (C7).
6. Inference never silently overwrites ground truth (C8).
7. The path-graph algorithm was chosen by measurement (ADR-001).

More detail: [`docs/architecture.md`](docs/architecture.md), [`docs/database.md`](docs/database.md), [`.planning/codebase/`](.planning/codebase/) (stack, conventions, concerns, testing).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

Semester project, RVCE CSE 2026. Educational use only.
