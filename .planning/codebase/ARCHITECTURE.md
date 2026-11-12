---
last_mapped_commit: d964f20c86bb18eb97a68714a415b6245809e1e2
last_mapped_at: 2026-11-13
---
<!-- refreshed: 2026-11-13 -->
# Architecture

**Analysis Date:** 2026-11-13

## System Overview

```text
┌──────────────────────────────────────────────────────────────────────────┐
│                    Flutter client: `apps/dispatcher`                      │
│  Roles: caller · dispatcher · mapper · admin (role from server token)     │
│  `lib/main.dart` shell · `lib/*_screen.dart` UI · `lib/core/*` offline    │
│        │ UI reads/writes                                                  │
│        ▼                                                                  │
│  `lib/core/local_store.dart` (sqflite, local SQLite outbox + cache)       │
│        ▲ push / pull                                                      │
│  `lib/core/sync_service.dart` ── HTTP (`http` package, bearer token)      │
└────────┬─────────────────────────────────────────────────────────────────┘
         │ REST JSON on :8090
         ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  `services/registry-api/src/server.js` — raw `node:http` router           │
│  auth (`auth.js`) · sync · dispatch · grievances · dedup · admin          │
│        │                                   │                              │
│        ▼                                   ▼                              │
│  `registry.js` (Registry, node:sqlite)   `dispatch.js` (DispatchBackend)  │
│  `feedback.js` · `disclosure.js` · `grievance.js` · `qr.js`               │
└────────┬───────────────────────────────────┬─────────────────────────────┘
         │ SQLite file (`DB_PATH`)           │ HTTP POST /v1/graph/route
         ▼                                   ▼ (optional, `GRAPH_URL`)
  Structural registry DB            `services/graph-service/src/server.py`
                                    (stdlib http.server, :8092 default)
                                    `routing.py` · `hybrid.py`

Shared, dependency-free library: `packages/sync-core/index.js`
(field CRDT, Lamport clock, outbox, idempotency ledger, cursor, connectivity gate)
Used by tests and the sync contract; intended to mirror the client-side logic.

Isolated, scaffolded services (not on the main request path):
- `services/consent-api/src/consent.js` (resident identity, separate DB by design)
- `services/change-detector/src/imagery_diff.js` (candidate generator stub)
```

## Pattern Overview

**Overall:** Offline-first, thin-client / monolithic-backend. A single Node.js process owns the structural registry and dispatch logic; a Flutter client keeps a full local SQLite copy and synchronises through an outbox. A small Python sidecar computes routes.

**Key Characteristics:**
- Server is a single hand-rolled HTTP router (`services/registry-api/src/server.js`, `createServer()` at ~line 40). No web framework, no middleware chain: each route is an `if (req.method === ... && url.pathname === ...)` branch.
- Persistence is `node:sqlite` `DatabaseSync` (`services/registry-api/src/registry.js` line 16) with schema applied in code (`applySchema()`, line 78). The `migrations/*.sql` files are Postgres/PostGIS artifacts and are not executed by the Node runtime.
- Identity is decided by humans, never auto-merged. Field-level merges are commutative (`packages/sync-core/index.js`, `mergeField`, line 79). Identity conflicts raise `IdentityMergeRefused` (`registry.js` line 37/60).
- Evidence model: every asserted value carries `evidence_class`; inference lands as `state='candidate'` and cannot overwrite ground truth (`registry.js` ~line 446, `feedback.js` line 136).
- Backend is pluggable by configuration: `createBackend(name, deps)` in `services/registry-api/src/dispatch.js` line 271 returns `InternalBackend` for every name today; the `DispatchBackend` base class defines the four-method contract.
- Route computation degrades gracefully: if `GRAPH_URL` is unset or the graph call fails, `server.js` returns `route: null` and never a fabricated path.
- Client role gating is enforced twice: UI tabs (`apps/dispatcher/lib/main.dart`, `UserRole` enum in `lib/auth_service.dart` line 14) and server guards (`requireRole(...)` inside `server.js`).

## Layers

**HTTP edge (registry-api):**
- Purpose: Parse request, resolve identity, dispatch to domain code, serialise JSON.
- Location: `services/registry-api/src/server.js`
- Contains: `json()` helper (CORS headers set here), `body()` reader, `requireRole()` guard, route branches.
- Depends on: `registry.js`, `dispatch.js`, `feedback.js`, `disclosure.js`, `auth.js`, `qr.js`
- Used by: Flutter client (`sync_service.dart`, `auth_service.dart`), tests in `services/registry-api/test/*http*.test.js`

**Domain / persistence (registry-api):**
- Purpose: Structures, zones, service records, dedup queue, breadcrumbs, grievances, tasks, sync ops and receipts.
- Location: `services/registry-api/src/registry.js` (923 lines, `class Registry` line 69)
- Contains: schema DDL, `push()` (line 625), `pull()` (812), `bootstrap()` (846), `decideDedup()` (366), `issueCode()` (322), `zoneFor()` (512), `deleteStructure()` (879, soft delete)
- Depends on: `node:sqlite`, `node:crypto`
- Used by: `server.js`, `feedback.js`, `dispatch.js`

**Dispatch (registry-api):**
- Purpose: Lookup a structure by code, compute route, record assignment and outcome.
- Location: `services/registry-api/src/dispatch.js`
- Contains: `DispatchBackend` (abstract, line 27), `InternalBackend` (line 59), `createBackend` (line 271)
- Depends on: `Registry` instance and an injected `router` function
- Used by: `server.js` `/v1/dispatch/*` routes

**Feedback / evidence (registry-api):**
- Purpose: Turn dispatch outcomes and grievances into candidate assertions and promotion decisions.
- Location: `services/registry-api/src/feedback.js` (`FeedbackEngine`, line 24), `SIGNAL_RANK`, `defaultPromoter`
- Depends on: `Registry`
- Used by: `server.js` `/v1/assertions/*`, `/v1/dispatch/outcome`

**Disclosure (registry-api):**
- Purpose: Controls what service data and aggregate stats each role may read. `DisclosureRefused` is thrown on violation.
- Location: `services/registry-api/src/disclosure.js` (251 lines)
- Used by: `server.js` service and stats endpoints

**Auth (registry-api):**
- Purpose: HMAC-style bearer token issue and verify, demo user table.
- Location: `services/registry-api/src/auth.js` (`AuthService`, line 44; `DEFAULT_USERS`, `DEV_SECRET` exported)
- Depends on: `node:crypto`
- Note: `X-Role` header is honoured only when `allowRoleHeader` is enabled (test-only opt-in). `server.js` line ~80 documents this.

**Shared sync logic (packages):**
- Purpose: Dependency-free CRDT field merge, Lamport clock, outbox, idempotency ledger, cursor, connectivity gate. Must behave identically in the mapper client, tests, and sync service.
- Location: `packages/sync-core/index.js` (334 lines)
- Contains: `CRDT_FIELDS_BY_TABLE` (line ~20), `mergeField`, `mergeFields`, `LamportClock`, `Outbox`, `IdempotencyLedger`, `Cursor`, `ConnectivityGate`
- Depends on: nothing
- Used by: `packages/sync-core/test/*.test.js`; the Dart client re-implements the outbox in `local_store.dart` (`pending_op` table, line 193)

**Route computation (graph-service):**
- Purpose: Walkable-network routing for dispatch. Two algorithms: plain graph and hybrid, with the hybrid one approved by M0 measurement (per `docs/architecture.md` §5.8).
- Location: `services/graph-service/src/server.py` (`Handler` line 34; `do_POST` line 82 handles `/v1/graph/route`), `routing.py` (`GraphRegistry`, `route`), `hybrid.py`
- Depends on: Python stdlib only at runtime
- Used by: `registry-api` through `GRAPH_URL` (`server.js` ~line 40-55). Guard comment at `server.py` line ~163: only the approved algorithm may serve dispatch routes (`serves_routes`).

**Client offline store (Flutter):**
- Purpose: Local truth for the device; queues every write as an outbox op.
- Location: `apps/dispatcher/lib/core/local_store.dart` (`LocalStore`, line 114)
- Tables: `local_structure`, `local_service`, `local_photo`, `pending_op`, `sync_state`, `breadcrumb_point`, `local_grievance`
- Depends on: `sqflite`, `sqflite_common_ffi` (desktop), `path_provider`, `uuid`, `crypto`
- Used by: `sync_service.dart`, all screens that write data, `gps_service.dart` for breadcrumbs

**Client sync (Flutter):**
- Purpose: Push outbox ops, pull zone changes, track cursor, notify UI.
- Location: `apps/dispatcher/lib/core/sync_service.dart` (`SyncService extends ChangeNotifier`, line 41)
- Endpoints used: `POST /v1/sync/push` (line 106), `GET /v1/sync/pull?zone=C4` (line 151)
- Depends on: `LocalStore`, `http`

**Client presentation (Flutter):**
- Purpose: Screens, shared components, design tokens.
- Location: `apps/dispatcher/lib/` (flat folder; see STRUCTURE.md)
- State management: `provider` package (`ChangeNotifierProvider` wraps `AuthService`, `SyncService`, settings in `main.dart`); screen-local `StatefulWidget` state otherwise.

## Data Flow

### Primary Request Path (dispatcher code lookup)

1. Dispatcher enters a code in `apps/dispatcher/lib/lookup_screen.dart`, which calls `POST /v1/dispatch/lookup` through the HTTP client.
2. `services/registry-api/src/server.js` (line ~230) resolves identity from `Authorization: Bearer` via `authService.verify()`, then calls the backend.
3. `InternalBackend.lookup()` in `services/registry-api/src/dispatch.js` reads the structure with `Registry.getByCode()` (`registry.js` line 490) and asks the injected router for a route.
4. Router is an HTTP POST to `GRAPH_URL/v1/graph/route` (`server.js` ~line 40-55); on any failure it returns `null`, and the response keeps the destination with `route: null`.
5. JSON response returns to the Flutter client, which renders it in `lookup_screen.dart`.

### Mapper Sync Path (offline capture to server)

1. Walk recording: `apps/dispatcher/lib/core/gps_service.dart` produces fixes; `mapper_screen.dart` and `local_store.dart` write `breadcrumb_point` rows and a `pending_op` row (`table: breadcrumb`) in one local flow. No network is required.
2. `SyncService` (`sync_service.dart` line ~100-110) reads pending ops from `LocalStore` and POSTs `{device_id, ops}` to `/v1/sync/push`.
3. `Registry.push()` (`registry.js` line 625) applies idempotency by `clientOpId` and `(device, trace, seq)`, records receipts, and returns accepted and rejected ids.
4. Client marks ops done; cursor advances via `sync_state`.
5. Dispatcher map reads breadcrumbs via `GET /v1/breadcrumbs` (`server.js` line 151) → `Registry.listBreadcrumbs()` (line 856).

### Dedup and Identity Path

1. A new structure created offline arrives by push; `Registry.generateDedupCandidate()` (line 256) checks proximity (default 12 m).
2. Candidate appears in `GET /v1/dedup` (`server.js` line 178) and the admin UI.
3. Reviewer calls `POST /v1/dedup/:id/decision`; `Registry.decideDedup()` (line 366) is the only place identity changes. It calls `issueCode()` (line 322) to mint the stable code.

### Grievance Path

1. `POST /v1/grievances` (`server.js` line 339) applies rate limits and weight checks from `services/registry-api/src/grievance.js` (`RATE_LIMIT`, `WEIGHT_ORDER`).
2. Triage via `POST /v1/grievances/:id/triage` (line 454) runs the rule-based state machine. There is no ML classifier.

### Feedback Loop

1. `POST /v1/dispatch/outcome` records success or failure through `InternalBackend.outcome()`.
2. `FeedbackEngine` (`feedback.js`) creates `inference` / `candidate` assertions. Promotion requires `defaultPromoter` and a human-visible verify call (`POST /v1/assertions/:id/verify`, `server.js` line 275).

**State Management:**
- Server: all durable state in one SQLite file at `DB_PATH` (default `:memory:` in code, `/data/registry.db` in `docker-compose.yml`). No in-process cache beyond the Node module instance.
- Client: `LocalStore` is the source of truth offline; `SyncService` and `AuthService` are `ChangeNotifier`s exposed through `provider`.

## Key Abstractions

**`Registry`:**
- Purpose: Owns the structural database and every write rule.
- Examples: `services/registry-api/src/registry.js` (class line 69)
- Pattern: Single class, methods per use case, SQL inline. Constructed with a DB path; tests pass `:memory:`.

**`DispatchBackend`:**
- Purpose: Contract for any dispatch implementation (`lookup`, `dispatch`, `outcome`, `capabilities`).
- Examples: `services/registry-api/src/dispatch.js` line 27 (base), line 59 (`InternalBackend`)
- Pattern: Strategy via configuration string. Add a new backend by extending the class and adding a `case` in `createBackend`.

**`FeedbackEngine` and assertions:**
- Purpose: Evidence-classed candidate values with promotion.
- Examples: `services/registry-api/src/feedback.js`, table `assertion` in `registry.js` schema (line ~129)
- Pattern: `evidence_class` + `state` columns; candidates are never read as ground truth.

**`LocalStore` / `pending_op` outbox:**
- Purpose: Offline write queue and local cache.
- Examples: `apps/dispatcher/lib/core/local_store.dart`, `packages/sync-core/index.js` (`Outbox`, line 158)
- Pattern: Write locally first, enqueue an op with a client-generated id, reconcile on push.

**`UserRole`:**
- Purpose: Client-side role enum, values `caller`, `dispatcher`, `mapper`.
- Examples: `apps/dispatcher/lib/auth_service.dart` line 14. The server also recognises `admin`.
- Pattern: Role is trusted from the server token only; the client uses it to pick tabs.

## Entry Points

**Registry API server:**
- Location: `services/registry-api/src/server.js` (`if (require.main === module)` block, line ~373)
- Triggers: `node services/registry-api/src/server.js` or the container in `services/registry-api/Dockerfile` (`docker-compose.yml` service `registry-api`, port 8090)
- Responsibilities: HTTP routing, auth, orchestration of the registry and dispatch backends

**Graph service:**
- Location: `services/graph-service/src/server.py` (`if __name__ == "__main__"` block, line ~190)
- Triggers: `python services/graph-service/src/server.py` with `PORT` (default 8092)
- Responsibilities: Serve `/v1/graph/route` and health; compare-only mode for evaluation

**Flutter application:**
- Location: `apps/dispatcher/lib/main.dart` (`void main() async`, line 29)
- Triggers: `flutter run`, `flutter build linux`, `flutter build apk` (CI in `.github/workflows/build-apk.yml` on `v*` tags)
- Responsibilities: Init `LocalStore` and auth, choose root by role (`_AuthGate`, line 128), render `_MainShell` (line 193) with the tab list

**Tests as entry points:**
- Node: `node --test services/registry-api/test/` and `packages/sync-core/test/`; `services/consent-api/test/consent.test.js`
- Python: `services/graph-service/test/test_hybrid.py`, `test_e2e_dispatch.py`
- Flutter: `apps/dispatcher/test/*.dart`
- Orchestration: `scripts/verify-all.sh`

## Architectural Constraints

- **Threading:** Node registry-api is single-threaded event loop; all DB calls are synchronous `node:sqlite` calls inside request handlers. Flutter UI runs on the main isolate; sqflite calls are async. Graph service is `BaseHTTPRequestHandler` (single-threaded per request in the default `HTTPServer`).
- **Global state:** `DEFAULT_USERS` and `DEV_SECRET` are module-level exports in `services/registry-api/src/auth.js`. `DEFAULT_USERS` is mutable through `AuthService.users` (a `Map`). `GraphRegistry` in `services/graph-service/src/routing.py` holds the loaded graph in memory.
- **Circular imports:** None detected. `server.js` is the only module that imports all the others. `feedback.js` and `dispatch.js` depend on `registry.js` but not the reverse.
- **Layering rule (documented, partly enforced):** Identity lives in a separate DB and service (`services/consent-api`), which the registry must not reach (C3). Today the consent service is standalone and not wired into `server.js`, so the boundary holds by absence rather than by test.
- **Duplicate logic:** `packages/sync-core` is the spec for merge and outbox rules, while `apps/dispatcher/lib/core/local_store.dart` and `sync_service.dart` re-implement them in Dart. Changes to one must be mirrored in the other.
- **Role model mismatch:** `docs/architecture.md` describes separate Mapper, Dispatcher and Resident apps. The code ships one Flutter app (`apps/dispatcher`) with all roles inside it, and `README.md` describes Caller, Dispatcher and Admin tabs.

## Anti-Patterns

### Trusting the `X-Role` header

**What happens:** `server.js` falls back to `req.headers['x-role']` when `allowRoleHeader` is set, and `x-user` supplies `userId` when no token is present.
**Why it's wrong:** Any client that can set headers can claim any role. The code already gates this behind an opt-in flag, but the flag comes from `authService.allowRoleHeader`, so the production default depends on that class.
**Do this instead:** Only use `authService.verify()` results for `role` and `userId` in new routes. Test code should mint real tokens with `AuthService.issueToken()` (`services/registry-api/src/auth.js`).

### Writing SQL in route handlers

**What happens:** Some routes run ad-hoc queries (`server.js` grievance and dedup branches) or reach into `registry.db` directly rather than calling a `Registry` method.
**Why it's wrong:** Bypasses the constraint checks and the receipt/idempotency pattern that `Registry.push()` uses.
**Do this instead:** Add a method on `Registry` (or the relevant domain module) and call it from the route, as `registry.deleteStructure(id)` is called from `DELETE /v1/admin/structures/:id`.

### Duplicating business rules in the Flutter client

**What happens:** Rules such as outbox ordering and role-based tab visibility are coded in both `local_store.dart`/`main.dart` and `packages/sync-core` or `server.js`.
**Why it's wrong:** The two copies drift silently. The offline-acceptance tests in `packages/sync-core/test/offline-acceptance.test.js` cannot see the Dart copy.
**Do this instead:** Keep server authority on decisions (`requireRole`, `Registry` guards). On the client, treat UI gating as cosmetic and mirror only what the tests cover.

## Error Handling

**Strategy:** Explicit status codes and typed error bodies from the server; domain errors are thrown as named classes and mapped to HTTP codes in the route.

**Patterns:**
- `json(res, code, body)` in `server.js` line 26 is the only response writer. Errors use `{error: '<code>', detail?: string}`.
- `requireRole()` returns `true` after writing a 401 or 403 so the caller can `return denied`.
- Routing failure never fails the request. `router` catches fetch errors and returns `null` (`server.js` ~line 50).
- Domain refusals use typed errors: `IdentityMergeRefused` (`registry.js` line 37), `DisclosureRefused` (`disclosure.js` line 58). Route code catches them and returns 4xx.
- Top-level `try/catch` wraps the router body in `server.js`; unexpected errors return 500.

## Cross-Cutting Concerns

**Logging:** `console.log` only in `server.js` startup line. Graph service silences `log_message` (`server.py` line 44). Flutter uses `debugPrint` and `print` ad hoc.
**Validation:** Inline per route (`b.device_id`, `b.ops || []`). No schema validator library is used. Dart models parse JSON in `models.dart` and `local_store.dart`.
**Authentication:** Signed bearer token, role verified server-side (`auth.js`). Client stores the token via `shared_preferences` (`auth_service.dart`). Demo accounts are in `DEFAULT_USERS`; `AUTH_SECRET` must be set in production (`README.md`).
**CORS:** Wildcard origin with `Content-Type, X-Role` allowed (`server.js` `json()` helper).

---

*Architecture analysis: 2026-11-13*
