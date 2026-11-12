---
last_mapped_commit: d964f20c86bb18eb97a68714a415b6245809e1e2
last_mapped_at: 2026-11-13
---
# Codebase Concerns

**Analysis Date:** 2026-11-13

## Tech Debt

**Auth is a stub at the HTTP edge; role-gating is incomplete:**
- Issue: Several state-changing and data-reading endpoints have no `requireRole` check at all. The server comment at `services/registry-api/src/server.js` says "Auth is stubbed at the edge (role header) — OIDC lands in M6", which is no longer accurate because bearer tokens now exist, but the route table was never fully migrated to them.
- Files: `services/registry-api/src/server.js` (unguarded: `POST /v1/sync/push`, `GET /v1/sync/pull`, `GET /v1/sync/bootstrap`, `GET /v1/breadcrumbs`, `GET /v1/structures`, `GET /v1/structures/:code`, `GET /v1/tasks`, `GET /v1/assertions/candidates`, `POST /v1/assertions/:id/verify`, `POST /v1/tasks/:id/complete`, `POST /v1/grievances`, `POST /v1/grievances/:id/triage`, `GET /v1/zones`)
- Impact: Anyone who can reach port 8090 can read the registry, push ops, and in some cases promote candidates to ground truth (see Security Considerations).
- Fix approach: Add an explicit auth middleware that resolves identity once, then a per-route policy table (method + path -> allowed roles, or `public`). Fail closed: unknown routes must not be reachable without a declared policy. Add a test that enumerates every route and asserts its policy.

**Role model is inconsistent between server and app:**
- Issue: The server issues `admin` and `reviewer` roles (`services/registry-api/src/auth.js` `DEFAULT_USERS`), and `services/registry-api/src/server.js` gates endpoints on `admin`. The Flutter `UserRole` enum only has `caller`, `dispatcher`, `mapper` (`apps/dispatcher/lib/auth_service.dart`). `UserRole.fromString` falls back to `caller` for unknown values, so an `admin` login is silently downgraded to a caller in the app. `isAdmin` returns `_currentRole == UserRole.dispatcher` ("dispatcher has admin powers"), which is a leftover of commit `6aa8900` (admin merged into dispatcher) and does not match the server's separate `admin` role.
- Files: `apps/dispatcher/lib/auth_service.dart` (enum, `fromString`, `isAdmin`, login at line ~91), `apps/dispatcher/lib/admin_screen.dart` (default `role = 'admin'`), `apps/dispatcher/lib/settings_screen.dart` (role dropdown includes `admin`), `services/registry-api/src/auth.js`
- Impact: Admin accounts see the caller UI; the admin screen cannot be reached through a real login; the app and server disagree on who can delete structures (server allows `admin` and `dispatcher`, app only shows admin UI to `dispatcher`).
- Fix approach: Decide whether `admin` is a separate role or an alias of `dispatcher` (the merge commit suggests alias). If alias, map it server-side in `auth.js` and remove the `admin` role from the token. If separate, add it to the Dart enum and remove the `isAdmin` special case. Either way, `fromString` should throw or return an explicit "unknown role" state, not default to `caller`.

**Two implementations of the sync contract:**
- Issue: The C5 push/pull logic exists in `packages/sync-core/index.js` (with its own tests) and again in Dart at `apps/dispatcher/lib/core/sync_service.dart` and `apps/dispatcher/lib/core/local_store.dart`. The server-side `push` lives in `services/registry-api/src/registry.js`. Nothing enforces that these three agree.
- Files: `packages/sync-core/index.js`, `packages/sync-core/test/*.test.js`, `apps/dispatcher/lib/core/sync_service.dart`, `services/registry-api/src/registry.js` (`push`, line ~625)
- Impact: Behaviour such as `dedup_required` handling, receipt idempotency, and op ordering can drift silently between client and server.
- Fix approach: Pick one canonical contract (`docs/api.md` plus `packages/sync-core`) and generate or share fixtures used by both the Dart and Node tests.

**Ad-hoc schema creation at request time:**
- Issue: The grievance handler runs `CREATE TABLE IF NOT EXISTS grievance` on every `POST /v1/grievances` request. A `grievance` table is also defined in `services/registry-api/migrations/000_init.sql`. Two schema sources for one table.
- Files: `services/registry-api/src/server.js` (grievance POST, around line 380-400)
- Impact: The runtime DDL can diverge from the migration; it also runs DDL on a hot path and can hide migration failures.
- Fix approach: Remove the inline `CREATE TABLE`; rely on migrations only and fail at boot if the table is missing.

**Module-level globals for business state:**
- Issue: Grievance rate-limit counters are stored in `global.__grievLimits`, and weights in `global.__grievWeights`. Both are process-global and lost on restart. Route handlers also write to `global`.
- Files: `services/registry-api/src/server.js` (grievance POST and triage handlers)
- Impact: Rate limits reset on every restart and do not hold across multiple API instances. Also a testing hazard: state leaks between tests in the same process.
- Fix approach: Move rate-limit state into a small class owned by `createServer` (or into SQLite if it must persist). Replace `global.__grievWeights` with a module constant (it is overwritten nowhere, so the `||` fallback is dead code).

**Duplicated weight table:**
- Issue: Evidence weights are defined twice in `services/registry-api/src/server.js`: once in the POST handler's `global.__grievWeights` fallback and once in the triage handler's `weights` object. The POST handler only ever reads `resident_report`.
- Files: `services/registry-api/src/server.js`
- Impact: Changing a weight in one place does not change the other.
- Fix approach: Single exported constant, referenced from both handlers and from `docs/M7_TRIGE_STATE_MACHINE.md`.

**Monolithic files:**
- Issue: `services/registry-api/src/registry.js` (923 lines), `services/registry-api/src/server.js` (527 lines, one `if`-chain route table), and several Dart screens over 900 lines (`apps/dispatcher/lib/inbound_call_screen.dart` 1024, `apps/dispatcher/lib/create_dispatch_screen.dart` 995, `apps/dispatcher/lib/components.dart` 968, `apps/dispatcher/lib/design_system.dart` 908, `apps/dispatcher/lib/dashboard_screen.dart` 905).
- Impact: Route ordering bugs are easy to introduce (the server already needed a comment about `/:code` swallowing `/:code/qr`).
- Fix approach: Split routes into a table keyed by method and pattern with per-route policy. Split screens into widgets per panel.

**Placeholder test script and no CI test gate:**
- Issue: `services/registry-api/package.json` has `"test": "echo \"Error: no test specified\" && exit 1"`, so `npm test` fails, even though `services/registry-api/test/*.test.js` exists. The only GitHub workflow, `.github/workflows/build-apk.yml`, builds the APK on tags and runs no tests. Verification relies on the manual `scripts/verify-all.sh`.
- Files: `services/registry-api/package.json`, `.github/workflows/build-apk.yml`, `scripts/verify-all.sh`
- Impact: Regressions in auth, sync, or grievance code can ship without any automated check.
- Fix approach: Set `"test": "node --test test/*.test.js"` in the registry-api package and add a workflow step (or a separate workflow on push) that runs `scripts/verify-all.sh` or the same node tests.

## Known Bugs

**Admin login is downgraded to caller in the app:**
- Symptoms: Logging in with the seeded `admin` account (`admin` / `admin123`) returns role `admin` from the server; the app maps it to `UserRole.caller` and shows the caller UI.
- Files: `apps/dispatcher/lib/auth_service.dart` (`fromString` default, login at line ~91)
- Trigger: Log in as `admin` in the dispatcher app.
- Workaround: Log in as `dispatcher`, which has the same server-side privileges for dispatch and structure deletion.

**Dart `isAdmin` getter does not match server admin:**
- Symptoms: Any UI gated on `isAdmin` shows only for `dispatcher`, not for the server `admin` role.
- Files: `apps/dispatcher/lib/auth_service.dart` (`isAdmin`)
- Trigger: Any account with server role `admin`.
- Workaround: None beyond the dispatcher login.

**Release Android build may block plain-HTTP API URLs:**
- Symptoms: The app's default and hinted API URLs are plain `http://` (`http://127.0.0.1:8090`, `http://192.168.1.5:8090`, `http://127.0.0.1:8092`). No `usesCleartextTraffic` or `network_security_config` was found under `apps/dispatcher/android/app/src`, so on Android 9+ release builds, cleartext requests to a LAN server are expected to fail. This was not verified on a device.
- Files: `apps/dispatcher/android/app/src/main/AndroidManifest.xml`, `apps/dispatcher/lib/main.dart` (`kDefaultApiUrl`, line 40), `apps/dispatcher/lib/login_screen.dart` (line ~146), `apps/dispatcher/lib/mapper_screen.dart` (line ~703)
- Trigger: Build a release APK and point it at a non-localhost HTTP server.
- Workaround: Test on a debug build or put the API behind HTTPS.

**Grievance dedup uses the wrong zone:**
- Symptoms: `POST /v1/grievances` opens its dedup task with `zone: 'C4'` regardless of the structure's real zone, and the triage handler does the same for mapper tasks.
- Files: `services/registry-api/src/server.js` (grievance POST `enqueueTask` call; triage `enqueueTask` call)
- Trigger: Submit a grievance against a structure outside zone C4.
- Workaround: Only the pilot zone is seeded, so this is latent.

**Grievance `structure_code` check is bypassed when omitted:**
- Symptoms: A grievance with no `structure_code` skips the cross-check and is stored with `cross_check_action: 'asserted'`, which reads as if it were confirmed against a structure.
- Files: `services/registry-api/src/server.js` (grievance POST, `if (structureCode)` block)
- Trigger: POST a grievance without `structure_code`.
- Workaround: None; the response value is misleading to clients.

## Security Considerations

**Unauthenticated promotion of candidates to ground truth (likely):**
- Risk: `POST /v1/assertions/:id/verify` and `POST /v1/tasks/:id/complete` have no `requireRole` check. The verifying identity is taken from `userId`, which is the verified token's username, or else the raw `X-User` header. The default promoter (`defaultPromoter` in `services/registry-api/src/feedback.js`) accepts any actor matching `^(mapper|dispatch|reviewer|admin|resident):`. A request with no token and the header `X-User: mapper:anything` would therefore satisfy the promoter. This was derived from reading the code and was not executed. The existing test `services/registry-api/test/feedback-http.test.js` only covers forging the actor in the body, not the header.
- Files: `services/registry-api/src/server.js` (`userId` fallback to `x-user`; verify and complete routes), `services/registry-api/src/feedback.js` (`defaultPromoter`, `verify`, `completeTask`)
- Current mitigation: The body `actor` field is ignored, and machine-prefixed actors (`ml`, `imagery`, `system`, `auto`, `graph`, `change-detector`) are refused.
- Recommendations: Ignore `X-User` unless `allowRoleHeader` is on (the same test-only gate as `X-Role`). Require a `verify`-capable role for both routes. Add a test that sends `X-User: mapper:x` with no token and expects 401 or 403.

**X-Role and X-User headers in the test-only path:**
- Risk: `X-Role` is honoured when `authService.allowRoleHeader` is true. That flag is set whenever the secret equals the dev default and `ALLOW_ROLE_HEADER !== '0'`. A production deploy that forgets `AUTH_SECRET` throws, but a deploy that sets `AUTH_SECRET` to the dev string, or sets `NODE_ENV` to something other than `production`, runs with spoofable roles. `X-User` is never gated.
- Files: `services/registry-api/src/auth.js` (`allowRoleHeader`, `getSecret`), `services/registry-api/src/server.js` (lines ~64-75, `userId`)
- Current mitigation: `getSecret` refuses to start in `NODE_ENV=production` without `AUTH_SECRET`.
- Recommendations: Gate `X-Role` and `X-User` on an explicit `ALLOW_ROLE_HEADER=1` env var, not on the secret value. Default off.

**Hardcoded demo credentials and dev signing secret:**
- Risk: `services/registry-api/src/auth.js` ships five default accounts with passwords in source (`caller`, `dispatcher`, `mapper`, `reviewer`, `admin`, each with a `*123` password), and the dev JWT-style secret `dev-only-change-me-in-production`. If `AUTH_USERS_JSON` is unset, these are live. Passwords are scrypt-hashed at boot, but the plaintext is in git.
- Files: `services/registry-api/src/auth.js` (`DEFAULT_USERS`, `DEV_SECRET`)
- Current mitigation: The file header says these are for the semester pilot and can be overridden by `AUTH_USERS_JSON`. `AUTH_SECRET` is required when `NODE_ENV=production`.
- Recommendations: Refuse to load `DEFAULT_USERS` unless an explicit `AUTH_DEMO=1` is set. Generate and print a random admin password on first boot. Do not rely on `NODE_ENV` to decide production; check for a required env var at startup.

**Tokens stored in plaintext on device; long lifetime:**
- Risk: The Flutter app stores the bearer token in `SharedPreferences` (`apps/dispatcher/lib/auth_service.dart`, key `auth_token`). Tokens are valid for 30 days (`issueToken` default `expiresInSec = 30 * 24 * 3600`) and are refreshable indefinitely through `/v1/auth/refresh` as long as they verify.
- Files: `apps/dispatcher/lib/auth_service.dart`, `services/registry-api/src/auth.js`, `services/registry-api/src/server.js` (`/v1/auth/refresh`)
- Current mitigation: Refresh requires a currently valid token; logout clears prefs.
- Recommendations: Use `flutter_secure_storage` (Keystore/Keychain). Shorten access-token lifetime and add revocation (the server has no revocation list, so a stolen token is valid for the full 30 days, and refresh extends it).

**No login rate limiting:**
- Risk: `POST /v1/auth/login` has no throttling or lockout. Combined with the default accounts, this is a straightforward brute-force target on any reachable deployment.
- Files: `services/registry-api/src/server.js` (login route), `services/registry-api/src/auth.js` (`login`)
- Current mitigation: scrypt with 32-byte output, which slows each guess but does not limit attempts.
- Recommendations: Per-username and per-IP attempt limits with backoff.

**Grievance endpoint is open and its rate limit is trivially bypassed:**
- Risk: `POST /v1/grievances` is unauthenticated. The rate limit keys on `device_hash` from the request body (`b.device_hash || 'unknown'`), which the client chooses, so rotating the value bypasses the 5/hour and 20/day caps. Triage (`POST /v1/grievances/:id/triage`) is also unauthenticated and accepts `source` from the body, so a caller can set the weight to `dispatch_feedback` (1.0) and move a grievance to `confirmed`.
- Files: `services/registry-api/src/server.js` (grievance POST, triage POST)
- Current mitigation: Responses are labelled `synthetic: true`. The state machine enforces legal transitions.
- Recommendations: Require auth on triage and derive the weight from the server-side evidence record, never from client `source`. Key rate limits on IP plus a server-issued token, not the body.

**Unauthenticated read of the whole registry:**
- Risk: `GET /v1/structures`, `GET /v1/structures/:code`, `GET /v1/sync/pull`, `GET /v1/sync/bootstrap`, `GET /v1/breadcrumbs`, and `GET /v1/zones` are open. `GET /v1/structures` with `include_deleted=true` returns soft-deleted records. Breadcrumb data is a movement trace. The PRD (§6.6) says service-level data is restricted to roles, and the disclosure module (`services/registry-api/src/disclosure.js`) enforces that only for `/services`. The bulk endpoints bypass it.
- Files: `services/registry-api/src/server.js`, `services/registry-api/src/disclosure.js`, `prd-informal-settlement-registry.md` (§6.6, §6.9)
- Current mitigation: `/services` requires a role; aggregate stats are the only public-facing service surface by design.
- Recommendations: Require at least a mapper or dispatcher token on sync, breadcrumb, and structure listing routes. Keep `GET /v1/structures/:code` public only if it returns no service data and the PRD explicitly accepts that.

**Municipal scope taken from a client header:**
- Risk: `readServiceData` receives `municipalScopes` from the `X-Scopes` request header, which the client supplies. Any caller can claim a municipal scope.
- Files: `services/registry-api/src/server.js` (`/services` route, `x-scopes` header), `services/registry-api/src/disclosure.js`
- Current mitigation: `municipal_ngo` role is not issued by any default user.
- Recommendations: Derive scopes from the verified token claims, never from a header.

**CORS wildcard with a custom auth header:**
- Risk: Every response sets `Access-Control-Allow-Origin: *` and allows `Content-Type, X-Role`. The bearer token is not a cookie, so CSRF is not the concern, but any web origin can call the API and read responses from an unauthenticated browser context.
- Files: `services/registry-api/src/server.js` (`json()` helper)
- Current mitigation: None needed for the Flutter app, which does not use a browser.
- Recommendations: Remove CORS headers unless a browser client is planned. Add `Authorization` to allowed headers if one is.

**Graph service has no authentication and binds broadly:**
- Risk: `services/graph-service/src/server.py` is a plain `http.server` on `PORT` (default 8092) with no auth. `services/registry-api/src/server.js` forwards route requests to it through `GRAPH_URL`.
- Files: `services/graph-service/src/server.py`, `services/registry-api/src/server.js` (router), `apps/dispatcher/lib/main.dart` (`kDefaultGraphUrl`)
- Current mitigation: Intended for a local network pilot.
- Recommendations: Bind to `127.0.0.1` by default, or put it behind the same auth as the registry API.

**Dispatcher console sends device-hash placeholders as device IDs:**
- Risk: `apps/dispatcher/lib/inbound_call_screen.dart` (line ~113) sends `device_hash: 'dispatcher_console_<timestamp>'` to the unauthenticated grievance endpoint. Not a leak, but it shows the device-hash field has no integrity guarantee.
- Files: `apps/dispatcher/lib/inbound_call_screen.dart`
- Recommendations: Derive device identity server-side from the token and device key; treat the body field as untrusted.

**Secrets handling in the repo:**
- Risk: `.env` files were not read (by design). `docker-compose.yml` contains no password lines (grep). `scripts/` was not scanned for embedded credentials.
- Files: `docker-compose.yml`
- Recommendations: Add a secret-scanning step to CI.

## Performance Bottlenecks

**Full-table scans on every zone-filtered grievance query:**
- Problem: `GET /v1/grievances?zone=...` loads every row of `structure` and computes distances in JavaScript on each request.
- Files: `services/registry-api/src/server.js` (grievance GET, zone branch)
- Cause: No spatial index is used; the filter is applied after `SELECT code, lat, lon FROM structure`.
- Improvement path: Use the PostGIS path (`services/registry-api/migrations/001_postgis_verify.sql`) or SQLite R-tree, or cache the code set per zone.

**Whole-table reads in sync endpoints:**
- Problem: `GET /v1/structures` returns every structure (`registry.allStructures`), and `GET /v1/breadcrumbs` defaults to `limit=5000` with no paging contract.
- Files: `services/registry-api/src/server.js`, `services/registry-api/src/registry.js`
- Cause: No pagination in the structure listing; clients fetch all rows.
- Improvement path: Add cursor pagination on `updated_at` and reuse `since` on the structures endpoint.

**Haversine recomputed per dedup candidate:**
- Problem: `services/registry-api/src/registry.js` computes distances against all structures on each create (`haversine`, line ~891), and the dedup check is linear.
- Files: `services/registry-api/src/registry.js`
- Cause: No spatial index on the structure table in SQLite.
- Improvement path: Pre-filter with a bounding box before haversine, or use the PostGIS index.

**Graph service rebuilds the graph per process:**
- Problem: `services/graph-service/src/server.py` calls `build_graph` at startup from local data and holds it in memory; there is no reload path.
- Files: `services/graph-service/src/server.py`, `services/graph-service/src/hybrid.py`
- Cause: Static graph; changes in the registry require a restart.
- Improvement path: Expose a reload endpoint behind auth, or rebuild on a timer when the source changes.

## Fragile Areas

**Route table in `server.js`:**
- Files: `services/registry-api/src/server.js`
- Why fragile: One `createServer` closure with about 30 `if (req.method === ... && url.pathname === ...)` branches. Regex matches use `split('/')[n]` indices (for example `url.pathname.split('/')[4]` for admin delete, `split('/')[3]` elsewhere). An extra or missing path segment silently changes the target id.
- Safe modification: Add a route test for every new path, and check the index used by `split` against the regex.
- Test coverage: `services/registry-api/test/http-e2e.test.js` and `feedback-http.test.js` cover some routes; the admin delete path and the grievance triage transitions have only partial coverage (`grievance.test.js` covers 7 assertions).

**Dedup-required ops are acknowledged on the device:**
- Files: `apps/dispatcher/lib/core/sync_service.dart` (the `case 'dedup_required'` branch adds the op to `acked`), `services/registry-api/src/registry.js` (`push`, `dedup_required` branch around line 705)
- Why fragile: The client treats `dedup_required` as acknowledged and removes it from the pending queue. The server records a receipt and returns `serverId` and `dedupCandidateId`, and the client acks the op. Whether the op payload survives on the server for later review was not confirmed; if it does not, a rejected or lost candidate leaves no copy on the device to retry.
- Safe modification: Keep the op's payload in the local store until the server reports `applied` after human review, or persist the payload on the server dedup candidate.
- Test coverage: `packages/sync-core/test/offline-acceptance.test.js` and `constraints.test.js` exist; no Dart test covers the `dedup_required` ack path (`apps/dispatcher/test/offline_capture_test.dart` should be checked).

**Dispatch backend is an interface with one implementation:**
- Files: `services/registry-api/src/dispatch.js`
- Why fragile: `DispatchBackend` base methods throw `not implemented`; only `InternalBackend` works. `createBackend` selects by `DISPATCH_BACKEND` env var (default `internal`); behaviour for an unknown name was not checked.
- Safe modification: Check `createBackend` for a default and an error on unknown names before adding an adapter.

**Global role header default:**
- Files: `services/registry-api/src/server.js` (`roleHeaderAllowed ? (req.headers['x-role'] || 'mapper') : null`)
- Why fragile: When the test fallback is on, a request with no header is treated as a `mapper`, so any unauthenticated test client silently gets mapper rights.
- Safe modification: Make the default `null`, and have tests set the header explicitly.

**Synthetic data mixed into production paths:**
- Files: `services/registry-api/src/server.js` (grievance routes), `docs/M8_LOCAL_STATUS.md`
- Why fragile: Grievance endpoints, the `grievance` table, the weights, and the rate limits are all marked `synthetic`, yet they are wired into the same server and DB as the real registry. Nothing separates them.
- Safe modification: Put synthetic/M7 features behind a feature flag (`GRIEVANCE_ENABLED`) that defaults off in the pilot build.

**Demo seed data in the migration:**
- Files: `services/registry-api/migrations/000_init.sql` (50 seed structures, the `-- Seed the pilot zone` block at line ~491)
- Why fragile: Seed rows and schema live in the same migration. Re-running or editing it affects the pilot dataset.
- Safe modification: Move seeds to a separate file, applied only in dev.

## Scaling Limits

**Single-process SQLite:**
- Current capacity: One Node process, one SQLite file at `DB_PATH` (default `:memory:` in `services/registry-api/src/server.js`; compose mounts `./data:/data`).
- Limit: Concurrent writers serialise; the PRD mentions 25 concurrent mappers in the live-cluster test, which is deferred (`docs/M8_LOCAL_STATUS.md`).
- Scaling path: The PostGIS migration path (`services/registry-api/migrations/001_postgis_verify.sql`, `scripts/setup-postgis.sh`) exists but is not the default. Choose one database for production and remove the other path from the active code.

**In-memory state per process:**
- Current capacity: Grievance rate limits and grievance weights live in `global` (see Tech Debt).
- Limit: Not shared across instances; reset on restart.
- Scaling path: Move to the database or Redis (the code comment already mentions Redis as the production intent).

**Default database is in-memory:**
- Current capacity: `new Registry(process.env.DB_PATH || ':memory:')` in `services/registry-api/src/server.js`.
- Limit: Running without `DB_PATH` loses all data on restart, with no warning.
- Scaling path: Fail at startup when `NODE_ENV=production` and `DB_PATH` is unset.

## Dependencies at Risk

**Node dependency declaration is minimal and the lockfile is optional in the image:**
- Risk: `services/registry-api/Dockerfile` runs `npm ci --omit=dev || npm install --omit=dev`. If the lockfile is out of sync, the fallback silently resolves new versions. The only runtime dependency is `qrcode` (`^1.5.4`).
- Impact: Non-reproducible builds for the registry API image.
- Migration plan: Remove the `|| npm install` fallback so a bad lockfile fails the build.

**Flutter SDK pinned to 3.24 in CI only:**
- Risk: `.github/workflows/build-apk.yml` pins Flutter `3.24`, while local setup is in `scripts/setup-flutter.sh`. The `pubspec.lock` is committed, but no version is recorded in the workflow comments.
- Impact: Local and CI builds can differ.
- Migration plan: Record the Flutter version in one place and reference it from both the script and the workflow.

**Custom tile fetch in `tile_layer.dart`:**
- Risk: `apps/dispatcher/lib/tile_layer.dart` (not reviewed in full) appears to implement its own tile fetch and error handling, with a broad `catch (_)` at line ~78. Maintenance burden and silent failure.
- Impact: Offline map tiles fail silently with no user-visible state.
- Migration plan: Use `flutter_map`'s built-in tile provider, or at least log the caught error.

## Missing Critical Features

**No token revocation or logout on the server:**
- Problem: Logout clears local prefs only. No server-side session list or denylist exists.
- Blocks: Revoking a lost device or a departed mapper before the 30-day expiry.

**No audit trail for privileged actions:**
- Problem: Structure deletion (`DELETE /v1/admin/structures/:id`, a soft delete in `registry.js`), dedup decisions, and verifications are stored, but the admin user, reason, and before-state of deletes are not recorded in an audit table. `deleteStructure` only sets `deleted_at`.
- Blocks: Post-incident review of who removed a structure; the PRD's accountability requirements.

**No deployment or backup procedure in code:**
- Problem: `docs/RUNBOOK.md` and `scripts/verify-all.sh` exist, but there is no backup script for `data/registry.db`. The M8 status doc lists backup/restore as deferred.
- Blocks: Any live deployment.

**No real dispatch backend (PRD §6.8 is explicitly deferred):**
- Problem: Only `InternalBackend` is implemented.
- Blocks: Integration with any municipal or NGO dispatch system.

## Test Coverage Gaps

**Auth and role routing on unguarded endpoints:**
- What's not tested: No test asserts that `POST /v1/assertions/:id/verify` rejects `X-User: mapper:...` with no token. No test covers `POST /v1/grievances/:id/triage` with a forged `source`.
- Files: `services/registry-api/test/auth.test.js`, `services/registry-api/test/feedback-http.test.js`, `services/registry-api/test/grievance.test.js`
- Risk: The two security findings above could ship unnoticed.
- Priority: High

**Admin role end to end:**
- What's not tested: The admin delete route (`DELETE /v1/admin/structures/:id`) is not covered by a role test in the reviewed files, and the Dart app's handling of server role `admin` is untested.
- Files: `services/registry-api/src/server.js`, `apps/dispatcher/lib/auth_service.dart`, `apps/dispatcher/test/widget_test.dart`
- Risk: The admin-to-caller downgrade and the admin delete path can regress without detection.
- Priority: High

**Dart app test coverage is thin:**
- What's not tested: The Dart test suite has four files (`apps/dispatcher/test/breadcrumb_map_test.dart`, `offline_capture_test.dart`, `tile_math_test.dart`, `widget_test.dart`). None covers login, token storage, the sync `dedup_required` path, or the admin screen.
- Files: `apps/dispatcher/test/`, `apps/dispatcher/lib/auth_service.dart`, `apps/dispatcher/lib/core/sync_service.dart`
- Risk: Auth and sync regressions in the mobile app are not caught.
- Priority: Medium

**Graph service and dispatch end-to-end:**
- What's not tested: `services/graph-service/test/test_e2e_dispatch.py` sends `X-Role` headers, which the production server ignores, so this test may pass against a test-only auth path. Real-deployment behaviour is untested.
- Files: `services/graph-service/test/test_e2e_dispatch.py`, `services/graph-service/src/server.py`
- Risk: False confidence in end-to-end dispatch.
- Priority: Medium

**Deferred verification items (from `docs/M8_LOCAL_STATUS.md`):**
- What's not tested: 100-structure dry run (not performed; 50 synthetic structures only), live-cluster load test (25 concurrent mappers, sync burst), real GPS capture (`lane_entry_exit.gpx` absent), security review and backup/restore, real imagery integration for zones C4 and C9.
- Files: `docs/M8_LOCAL_STATUS.md`, `scripts/verify-all.sh`
- Risk: The pilot's field-accuracy claims are unverified. The M8 document itself says "Field accuracy: UNVERIFIED."
- Priority: High before any field use

**Document drift in the PRD and docs:**
- What's not tested: The PRD is at `prd-informal-settlement-registry.md` (v2, "Draft v2 — open for team review"). Git status shows the PDF version was deleted and the markdown added in the same staged change, and §6.2 is marked superseded in `docs/M8_LOCAL_STATUS.md` without a PRD amendment ("PRD unchanged" by instruction). The server header comment still says "OIDC lands in M6", which conflicts with the implemented bearer-token model.
- Files: `prd-informal-settlement-registry.md`, `docs/M8_LOCAL_STATUS.md`, `services/registry-api/src/server.js` (header comment), `docs/api.md`
- Risk: Readers cannot tell which decisions are current.
- Priority: Low

---

*Concerns audit: 2026-11-13*
