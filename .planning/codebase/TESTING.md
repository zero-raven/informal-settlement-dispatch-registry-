---
last_mapped_commit: d964f20c86bb18eb97a68714a415b6245809e1e2
last_mapped_at: 2026-11-13
---
# Testing Patterns

**Analysis Date:** 2026-11-13

## Test Framework

**JavaScript (Node):**
- Runner: Node built-in test runner `node:test` (no Jest, no Mocha)
- Assertions: `node:assert` (`assert.strictEqual`, `assert.deepStrictEqual`,
  `assert.throws`, `assert.ok`)
- Config: none. No `package.json` test script for the registry; see "Run Commands".
- Requires Node with `node:sqlite` (`DatabaseSync`), i.e. a recent Node 22.x line.

**Python:**
- Runner: `pytest` (imports `pytest`, uses `@pytest.fixture(scope="module")`)
- Assertions: plain `assert`, plus `numpy` in graph tests
- Config: none committed (no `pytest.ini`, `pyproject.toml`, `setup.cfg`).
- Expected virtualenv: `.venv-spike/` (referenced in the module docstring of
  `services/graph-service/test/test_hybrid.py`)

**Flutter / Dart:**
- Runner: `flutter test` (package `flutter_test`)
- Assertions: `expect(...)` with matchers (`greaterThan`, `findsOneWidget`)
- Config: `apps/dispatcher/analysis_options.yaml` (lints only)
- Dev dependency: `flutter_lints: ^4.0.0`

**Shell:**
- Acceptance scripts in `scripts/` print `✓` / `✗` lines and exit non-zero on failure:
  `scripts/verify-all.sh`, `scripts/registry-schema-test.sh`,
  `scripts/c3-isolation-test.sh`, `scripts/postgis-verify.sh`

## Run Commands

**Full suite (preferred entry point):**
```bash
./scripts/verify-all.sh                    # runs every section, prints pass/fail per milestone
```

**JavaScript, per package:**
```bash
cd packages/sync-core && node --test test/*.test.js           # M1 sync-core constraints
cd services/registry-api && node --test test/*.test.js        # M2 registry, sync, dedup, QR
cd services/consent-api && node --test test/*.test.js         # M6 consent vault
node --test services/registry-api/test/registry.test.js       # single file
node --test --test-name-pattern="C1/C2" packages/sync-core/test/constraints.test.js   # single test by name
```

**Python:**
```bash
.venv-spike/bin/python -m pytest services/graph-service/test/ -q
.venv-spike/bin/python -m pytest services/graph-service/test/test_hybrid.py -q
```

**Dart / Flutter:**
```bash
cd apps/dispatcher && flutter test
cd apps/dispatcher && flutter test test/tile_math_test.dart
```

**Coverage:**
- Not configured. No `c8`, `nyc`, `coverage` script, or `--experimental-test-coverage` in use.
  `node --test --experimental-test-coverage` is available if needed.

**Known gap in the registry-api package:**
- `services/registry-api/package.json` has `"test": "echo \"Error: no test specified\" && exit 1"`.
  `npm test` in that directory fails. Use `node --test test/*.test.js` or `verify-all.sh`.
- `services/registry-api/src/qr.js` requires `qrcode` (declared in
  `services/registry-api/package.json`). Any test that loads `server.js` or
  `qr.js` needs `npm install` in `services/registry-api/` first. In the current
  worktree, `node_modules` is NOT installed, so those suites fail on
  `require('qrcode')` until installation. Do not install as part of test
  analysis. Run `npm install` in that directory before running the suite.

## Test File Organization

**Location:** All tests live in a sibling `test/` directory, separate from source:

| Package | Test directory | Source |
|---------|----------------|--------|
| sync-core | `packages/sync-core/test/` | `packages/sync-core/index.js` |
| registry-api | `services/registry-api/test/` | `services/registry-api/src/` |
| consent-api | `services/consent-api/test/` | `services/consent-api/src/` |
| graph-service | `services/graph-service/test/` | `services/graph-service/src/` |
| dispatcher app | `apps/dispatcher/test/` | `apps/dispatcher/lib/` |

No co-located tests. `services/change-detector/src/imagery_diff.js` has no tests.

**Naming:**
- JavaScript: `<topic>.test.js`, kebab-case when the topic has two words:
  `feedback-http.test.js`, `offline-acceptance.test.js`, `review-fixes.test.js`
- Python: `test_<topic>.py`: `test_hybrid.py`, `test_e2e_dispatch.py`
- Dart: `<topic>_test.dart`: `tile_math_test.dart`, `offline_capture_test.dart`,
  `breadcrumb_map_test.dart`
- `widget_test.dart` is the Flutter template default name

**Test inventory (approximate `test(` counts, from the repo at analysis time):**

| File | Tests |
|------|-------|
| `packages/sync-core/test/constraints.test.js` | 16 |
| `packages/sync-core/test/offline-acceptance.test.js` | 3 |
| `services/registry-api/test/registry.test.js` | 26 |
| `services/registry-api/test/dispatch.test.js` | 15 |
| `services/registry-api/test/disclosure.test.js` | 15 |
| `services/registry-api/test/feedback.test.js` | 18 |
| `services/registry-api/test/grievance.test.js` | 7 |
| `services/registry-api/test/auth.test.js` | 5 |
| `services/registry-api/test/feedback-http.test.js` | 5 |
| `services/registry-api/test/review-fixes.test.js` | 5 |
| `services/registry-api/test/breadcrumbs.test.js` | 3 |
| `services/registry-api/test/http-e2e.test.js` | 2 |
| `services/registry-api/test/postgis-registry.test.js` | skipped unless PostGIS present |
| `services/consent-api/test/consent.test.js` | 12 |
| `services/graph-service/test/test_hybrid.py` + `test_e2e_dispatch.py` | 21 `def test_` functions combined |
| `apps/dispatcher/test/*.dart` | 13 (`offline_capture` 5, `breadcrumb_map` 2, `tile_math` 3, `widget_test` 3 `testWidgets`) |

Note: `apps/dispatcher/test/widget_test.dart` holds three `testWidgets` smoke
tests (including the sign-in gate on first run). They depend on `AuthService`
initialisation and an unreachable `baseUrl`.

## Test Structure

**Constraint-first suites (JavaScript):**
Tests are organised around PRD constraints. Each test name or banner cites the
constraint ID. A test is written to FAIL when the constraint is broken.

```js
// ---------------------------------------------------------------------------
// C1/C2 — identity is never decided by the sync layer
// ---------------------------------------------------------------------------

test('C1/C2: merging an identity field is refused', () => {
  assert.throws(
    () => mergeFields({}, { code: { value: 'SLR-C40001', lamport: 5, siteId: 'a' } },
      { table: 'structure' }),
    IdentityMergeRefused,
  );
});
```
Source: `packages/sync-core/test/constraints.test.js`

**Setup pattern: fresh in-memory registry per test.**
```js
function newRegistry() {
  const r = new Registry(':memory:');
  r.db.prepare("INSERT INTO app_user (id,email,role) VALUES ('m1','m@x','mapper')").run();
  r.db.prepare(
    "INSERT INTO zone (code,name,lat,lon,radius_m,dispatch_enabled) VALUES " +
    "('C4','Pilot campus',12.97,77.59,600,0)",
  ).run();
  return r;
}
```
Source: `services/registry-api/test/dispatch.test.js`. Seed data with raw SQL
through `r.db.prepare(...)`. Do not use a fixture library.

**Teardown:** Explicit, inside `finally`:
```js
async function withServer(fn, opts = {}) {
  const server = createServer(opts);
  await new Promise((res) => server.listen(0, res));
  const base = `http://127.0.0.1:${server.address().port}`;
  // ...
  try { return await fn(call, server); } finally { server.close(); }
}
```
Port `0` is used so parallel runs never collide. Every HTTP test wraps the server
in a `withServer(async (call) => { ... })` helper.

**Consent store setup (consent-api):**
```js
function store() {
  const db = new DatabaseSync(':memory:');
  db.exec('PRAGMA foreign_keys = ON');
  return new ConsentStore(db);
}
```
Source: `services/consent-api/test/consent.test.js`. Always enable foreign keys.

**Python fixtures:**
```python
@pytest.fixture(scope="module")
def dataset():
    return generate_dataset(seed=7)

@pytest.fixture(scope="module")
def graph(dataset):
    gt, traces = dataset
    return build_graph(traces, build_version=1)
```
Source: `services/graph-service/test/test_hybrid.py`. Module-scoped fixtures
with fixed seeds for determinism.

**Dart setup:**
```dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late String tempDir;
  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('mapper-test-').path;
    PathProviderPlatform.instance = _FakePathProvider(tempDir);
  });
}
```
Source: `apps/dispatcher/test/offline_capture_test.dart`. Use the real
`LocalStore` on a temp directory, not a mock.

## Mocking

**JavaScript: no mocking library.** Use real collaborators where possible:
- In-memory SQLite (`new Registry(':memory:')`, `new DatabaseSync(':memory:')`)
- Real HTTP server on an ephemeral port (`server.listen(0, ...)`) with global `fetch`
- Dependency injection through constructor/factory options:
  `createServer({ registry, router, auth, allowRoleHeader: true })`,
  `new InternalBackend({ registry, router })`

**Injecting a fake router (preferred pattern):**
```js
// services/registry-api/src/server.js accepts a router function in place of graph-service
createServer({ router: async (from, to) => ({ ... }) })
```
Pass a plain async function. Do not stub `fetch` globally.

**Auth in tests:** `createServer({ allowRoleHeader: true })` lets tests send an
`X-Role` header instead of a token. Production code must not set this flag
(see the header of `services/registry-api/src/auth.js`). Tests that exercise
real tokens use `AuthService` directly.

**Python:** No mocking library observed. The graph tests use real generated
datasets (`generate_dataset(seed=7)` from `spike/m0_ground_truth.py`) and a
subprocess-based e2e test (`services/graph-service/test/test_e2e_dispatch.py`
imports `subprocess`, `urllib.request`).

**Dart:** Platform-level fakes, not mocks of app classes.
```dart
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  // ...
}
```
Source: `apps/dispatcher/test/offline_capture_test.dart`,
`apps/dispatcher/test/breadcrumb_map_test.dart`. Register via
`PathProviderPlatform.instance = ...`. `SharedPreferences.setMockInitialValues({})`
is used in `apps/dispatcher/test/widget_test.dart`.

**What to mock:**
- Platform channels (path provider, shared preferences)
- The network edge for the Flutter app (`baseUrl` pointed at an unreachable
  host, e.g. `http://127.0.0.1:1` in `widget_test.dart`)
- The external graph router (pass a function)

**What NOT to mock:**
- The SQLite layer. Tests use real `:memory:` databases so schema, CHECK
  constraints, and triggers are exercised.
- The CRDT merge in `packages/sync-core/index.js`. Tests call the real functions.
- Identity and disclosure guards. Their tests must hit the real code path,
  because the constraint is the point of the test.

## Fixtures and Factories

**Inline fixtures dominate.** Test data is written in each test or in a small
local helper function. There is no shared fixtures directory.

**Shared test data:**
- `spike/m0_ground_truth.py` generates synthetic settlement datasets (`generate_dataset`)
- `spike/m0_results.json`, `spike/m0_results_multiseed.json`,
  `spike/m0_noise_sweep.json` are reference outputs for the regression gate in
  `services/graph-service/test/test_hybrid.py`

**Payload shape example** (from `services/registry-api/test/http-e2e.test.js`):
```js
{
  clientOpId: 'a1', clientSeq: 1, table: 'local_structure', op: 'create',
  payload: {
    centroid: { lat: 12.97, lon: 77.59 },
    structure_type: 'standalone_dwelling',
    entrance_geom: { lat: 12.97, lon: 77.59 },
    entrance_independent: true,
  },
}
```

**Location:** Fixtures are local to each test file. Synthetic geographic data
uses the pilot campus coordinates near `12.97, 77.59`.

**Dart tile fixture:** Pure math inputs, e.g. `TileMath.tileFor(12.97, 77.59, 15)`
in `apps/dispatcher/test/tile_math_test.dart`.

**Real-database check:** `services/registry-api/test/postgis-registry.test.js`
runs against `services/registry-api/migrations/000_init.sql` on real PostGIS. It
skips with a loud warning when `.pgroot/postgis.conf` is absent. Setup is
`./scripts/setup-postgis.sh`.

## Coverage

**Requirements:** None enforced. No threshold in any config or CI workflow.

**CI:** `.github/workflows/build-apk.yml` builds the Flutter APK on `v*` tags. It
does NOT run any test suite. Tests run locally through `scripts/verify-all.sh`.

**View coverage (Node):**
```bash
cd services/registry-api && node --test --experimental-test-coverage test/*.test.js
```

## Test Types

**Constraint/acceptance tests (dominant):**
- Scope: Each suite pins one PRD constraint or milestone deliverable (C1–C8,
  M1–M6). Examples: C1/C2 identity, C3 isolation, C4 offline, C7 zone gating,
  C8 evidence classes.
- Files: `packages/sync-core/test/*.test.js`, `services/registry-api/test/*.test.js`,
  `services/consent-api/test/consent.test.js`

**Unit tests:**
- Pure logic: merge, tile math, routing (`services/graph-service/test/test_hybrid.py`).
- Scope: One module, in-memory state, no network.

**Integration tests:**
- In-process HTTP over a real socket: `services/registry-api/test/http-e2e.test.js`,
  `feedback-http.test.js`.
- Subprocess graph-service end-to-end: `services/graph-service/test/test_e2e_dispatch.py`.
- Flutter app over real sqflite FFI: `apps/dispatcher/test/offline_capture_test.dart`.

**Schema tests (shell + psql):**
- `scripts/registry-schema-test.sh` applies migrations to a live Postgres and asserts
  C8 invariants. Spatial behaviour is NOT verified there (PostGIS geometry is shimmed).
- `scripts/c3-isolation-test.sh` checks identity is not reachable from the registry.

**E2E tests:** Not used for the Flutter app. No `integration_test/` directory.

## Common Patterns

**Async HTTP testing:**
```js
test('HTTP: full journey over a real socket', async () => {
  await withServer(async (call) => {
    const push = await call('POST', '/v1/sync/push', { device_id: 'dev1', ops: [...] });
    assert.strictEqual(push.status, 200);
  });
});
```
Source: `services/registry-api/test/http-e2e.test.js`. Use `call` (the helper
returns `{ status, body }`) and assert on both.

**Error and refusal testing (JavaScript):**
```js
assert.throws(
  () => c.setConsent({ residentId: r.id, scope: 'read_my_mind', granted: true }),
  /unknown scope/,
);
```
Use a regex for the message when the class is not exported. Use the class
(`IdentityMergeRefused`) when it is.

**Refusal-as-HTTP-status testing:** Assert the status code and the `error` field
together, e.g. `assert.strictEqual(r.status, 404)` plus the `error` key.

**Determinism:** Seed every generator (`generate_dataset(seed=7)`). Use
`Date`-independent fixtures where the clock matters, and inject the clock
(`LamportClock`) instead of reading wall time.

**Async Dart testing:**
```dart
test('capture works with no network and queues for sync', () async {
  // exercise LocalStore against a real temp-dir sqflite database
});
```
Use `async` test bodies directly. Use `setUp` to create a fresh temp directory
per test.

**Error Dart testing:**
Assert the value, not a thrown exception, when the app reports failure through
`SyncOutcome.error`. Source: `apps/dispatcher/lib/core/sync_service.dart`.

**Name tests after the behaviour:** `'C2: two mappers merging the same field both survive deterministically'`,
`'a new resident has no consent for anything'`. Keep the constraint ID prefix for
PRD-level tests.

## Adding a New Test

1. Pick the matching `test/` directory from the table above.
2. Name the file `<topic>.test.js` (JS), `test_<topic>.py` (Python), or
   `<topic>_test.dart` (Dart).
3. Start with `'use strict';` and the `node:test` / `node:assert` requires
   (JS). Copy the header comment style that cites the PRD section.
4. Use `new Registry(':memory:')` or `new DatabaseSync(':memory:')` for DB state.
5. Add the file to `scripts/verify-all.sh` only if it belongs to a new milestone
   section. The script runs `test/*.test.js` globs, so new files in those directories are picked up automatically.
6. Run `./scripts/verify-all.sh` before reporting a change as done.

---

*Testing analysis: 2026-11-13*
