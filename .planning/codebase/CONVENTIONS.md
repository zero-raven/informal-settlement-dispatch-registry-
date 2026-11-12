---
last_mapped_commit: d964f20c86bb18eb97a68714a415b6245809e1e2
last_mapped_at: 2026-11-13
---
# Coding Conventions

**Analysis Date:** 2026-11-13

## Scope of This Repo

The repository is polyglot. Each sub-tree follows its own conventions. Match the
conventions of the sub-tree you are editing, not a repo-wide style:

| Area | Language | Path | Notes |
|------|----------|------|-------|
| Registry HTTP API + core | JavaScript (CommonJS, Node built-ins) | `services/registry-api/src/` | `'use strict';` in every file |
| Sync core (shared CRDT/outbox) | JavaScript (CommonJS, zero deps) | `packages/sync-core/index.js` | Must stay dependency-free |
| Consent vault | JavaScript (CommonJS) | `services/consent-api/src/consent.js` | Uses `node:sqlite` |
| Change detector | JavaScript | `services/change-detector/src/imagery_diff.js` | Single file, no package manifest |
| Graph/routing service | Python 3 | `services/graph-service/src/*.py` | `from __future__ import annotations` |
| Spike/research tools | Python 3 | `spike/*.py`, `services/graph-service/tools/*.py` | Research code, looser style |
| Mapper/dispatcher app | Dart / Flutter (SDK `^3.5.4`) | `apps/dispatcher/lib/` | Linted with `flutter_lints` |
| Shell tooling | Bash | `scripts/*.sh`, `spike/run.sh` | `set -uo pipefail` |
| SQL | PostgreSQL/PostGIS DDL | `services/*/migrations/*.sql` | Numbered migrations |

Flutter platform folders (`apps/dispatcher/android`, `linux`) are generated and
out of scope for these conventions.

## Naming Patterns

**JavaScript files:**
- Lowercase single words, or kebab-case for test files: `registry.js`,
  `dispatch.js`, `disclosure.js`, `feedback-http.test.js`,
  `offline-acceptance.test.js`
- Exception: `services/change-detector/src/imagery_diff.js` (snake_case)

**Python files:**
- `snake_case.py`: `hybrid.py`, `routing.py`, `m0_algorithms.py`,
  `test_hybrid.py`, `test_e2e_dispatch.py`

**Dart files:**
- `snake_case.dart`: `local_store.dart`, `sync_service.dart`,
  `create_dispatch_screen.dart`, `tile_math_test.dart`
- Screens end in `_screen.dart`; services in `*_service.dart`; tests in
  `*_test.dart` under `apps/dispatcher/test/`

**Functions and methods:**
- JavaScript: `camelCase` (`mergeField`, `mergeFields`, `fieldsDiffer`,
  `createBackend`, `renderQr`, `readServiceData`, `aggregateStats`)
- Python: `snake_case` (`build_graph`, `suppress_spurious`, `path_recovery`,
  `generate_dataset`)
- Dart: `lowerCamelCase` (`tileFor`, `zoomForSpan`, `globalPixel`)

**Classes:**
- `PascalCase` in all three languages: `Registry`, `InternalBackend`,
  `DispatchBackend`, `LamportClock`, `ConsentStore`, `GraphRegistry`,
  `SyncService`, `LocalStore`, `ServiceRecord`
- Error classes extend `Error` and set `this.name`, e.g.
  `IdentityMergeRefused` in `packages/sync-core/index.js` and
  `services/registry-api/src/registry.js`

**Constants:**
- `SCREAMING_SNAKE_CASE` for module-level tables and sets:
  `CRDT_FIELDS_BY_TABLE`, `IDENTITY_FIELDS` (`packages/sync-core/index.js`),
  `DEFAULT_USERS`, `DEV_SECRET`, `PORT` (`services/registry-api/src/auth.js`,
  `server.js`), `SCOPES` (`services/consent-api/src/consent.js`)
- Dart: `static const _minInterval = Duration(seconds: 30);` in
  `apps/dispatcher/lib/core/sync_service.dart`

**Private members:**
- Dart: leading underscore for library-private (`_FakePathProvider`, `_online`,
  `_busy`, `_pump`)
- JavaScript: no underscore convention observed; encapsulation is by module
  scope (non-exported helpers such as `json`, `body` inside `createServer`)
- Python: no underscore convention observed in the graph service

**Database identifiers:**
- `snake_case` tables and columns: `app_user`, `structure_service`,
  `entrance_independent`, `dispatch_enabled`, `radius_m`, `compound_root_id`
- Lamport/sync fields use camelCase in JS payloads (`siteId`, `clientOpId`,
  `clientSeq`, `deviceId`). HTTP bodies accept snake_case (`device_id`) and
  camelCase in different endpoints. Follow the endpoint's existing style.

**Structure codes and identifiers:**
- Structure codes are prefixed strings (e.g. `SLR-C40001` in
  `packages/sync-core/test/constraints.test.js`). Treat them as opaque strings.

## Code Style

**JavaScript:**
- CommonJS only: `require(...)` and `module.exports = { ... }`. No ESM.
- Every source and test file starts with a JSDoc-style block comment that
  states the PRD/constraint it implements (e.g. `services/registry-api/src/dispatch.js`,
  `services/consent-api/test/consent.test.js`), followed by `'use strict';`.
- Use Node built-in modules with the `node:` prefix: `node:crypto`,
  `node:test`, `node:assert`, `node:sqlite`, `node:child_process`.
- Semicolons on every statement; single quotes for strings; 2-space indent;
  trailing commas in multi-line literals.
- Compact one-liners are used for trivial bodies:
  `try { return await fn(call, base); } finally { server.close(); }` and
  `catch { return null; }`.
- No formatter or linter config is committed (no `.eslintrc*`,
  `.prettierrc*`, `biome.json`). The only lint signal is inline:
  `// eslint-disable-next-line no-unused-vars` on abstract methods in
  `services/registry-api/src/dispatch.js`. Do not add a new linter config
  without asking.
- Sentence-like comments explain WHY, referencing PRD and constraint IDs:
  `// C4/C7: dispatch starts OFF. The pilot kill switch must be explicit.`

**Python:**
- `from __future__ import annotations` at the top of modules.
- Standard import groups: stdlib, third-party, local `sys.path` manipulation.
- `# noqa: E402` on imports that follow `sys.path.insert(...)`:
  `services/graph-service/src/server.py`, `services/graph-service/test/test_hybrid.py`.
- Type hints on public signatures (`version: int | None = None`,
  `def rebuild_in_progress(self) -> bool:`).
- Module docstrings describe the milestone (M3, M6) and the constraint being pinned.

**Dart:**
- Standard Flutter style with `package:flutter_lints/flutter.yaml` included from
  `apps/dispatcher/analysis_options.yaml`. No custom rules are enabled.
- Library-level `///` doc comments at file top, with `library;` directive when
  used (`apps/dispatcher/lib/core/sync_service.dart`).
- Doc comments on public types cite PRD sections: `/// PRD 6.1 — ...`,
  `/// PRD 6.6 — service data is sensitive operational data`.
- `final` fields in constructors with named `required` parameters
  (`SyncOutcome` in `apps/dispatcher/lib/core/sync_service.dart`).
- Relative imports within `lib/` (`import 'local_store.dart';`) and
  `package:dispatcher/...` in tests.

**SQL:**
- Numbered migration files: `000_init.sql`, `001_postgis_verify.sql`,
  `002_feedback.sql` under `services/registry-api/migrations/`.
- Inline `CHECK` constraints and triggers to enforce invariants at the database
  level (C1/C2/C8), not only in application code.

**Shell:**
- `#!/usr/bin/env bash`, `set -uo pipefail`, `cd "$(dirname "$0")/.."`.
- Helper functions `section`, `ok`, `bad` for coloured output in `scripts/verify-all.sh`.

## Import Organization

**JavaScript order (observed):**
1. `node:` built-ins (`const crypto = require('node:crypto');`)
2. Test framework (`const test = require('node:test');`, `const assert = require('node:assert');`)
3. Local modules via relative paths (`require('../src/registry.js')`). Include
   the `.js` extension on local requires.

**Dart order:**
1. `dart:` SDK imports
2. `package:` imports (alphabetical in practice)
3. Relative imports within `lib/`

**Path aliases:** None. All JS requires are relative; all Dart package imports
use the `package:dispatcher/` name.

## Error Handling

**Core JavaScript (registry-api):**
- Domain errors are thrown as plain `Error` with a descriptive message:
  `throw new Error(\`no such structure ${structureId}\`)` in
  `services/registry-api/src/registry.js`.
- Constraint violations use dedicated error classes so callers can branch on
  `instanceof`: `IdentityMergeRefused` (carries `.field`), `DisclosureRefused`
  (`services/registry-api/src/disclosure.js`).
- Where a failure must degrade rather than propagate, return `null`:
  `services/registry-api/src/auth.js` (`catch { return null; }`) and the graph
  router in `services/registry-api/src/server.js` ("Any failure degrades to route:null").
- Optional catch binding (`catch {`) is used when the error value is unused.

**HTTP layer (`services/registry-api/src/server.js`):**
- Each route is a branch on `req.method` and `url.pathname`, returning through
  the `json(res, code, body)` helper.
- Error responses are JSON `{ error: '<snake_case_code>', ... }`:
  `{ error: 'not_found', path }`, `{ error: 'structure_not_found', id }`,
  `{ error: 'internal', detail: e.message }`.
- Role gating uses `requireRole('admin', 'dispatcher')` and returns early with
  the denial response (`if (denied) return denied;`).
- Map domain exceptions to 4xx at the route, and let unexpected errors reach the
  top-level `catch` that returns 500.

**Dart:**
- Network and storage calls are wrapped in `try { ... } catch (e) { ... }`. Use
  `catch (_)` only where the failure is expected and non-actionable.
  Example: `apps/dispatcher/lib/main.dart` and `apps/dispatcher/lib/core/gps_service.dart`.
- Sync failures are reported as values, not thrown: `SyncOutcome` carries an
  `error` string and `attempted` flag (`apps/dispatcher/lib/core/sync_service.dart`).
- Offline is a normal state. Do not add retry loops or assume connectivity
  (see the header comment in `sync_service.dart`).

**Python:**
- HTTP handlers in `services/graph-service/src/server.py` return JSON payloads
  via the `_send(code, payload)` helper on `BaseHTTPRequestHandler`. No custom
  exception hierarchy was observed.

## Logging

**JavaScript:** `console.log` for startup banners only
(`services/registry-api/src/server.js`). No logging library.

**Dart:** No structured logger. Errors are surfaced to the UI through `ScaffoldMessenger`/`SnackBar` feedback
(see `apps/dispatcher/lib/admin_screen.dart`, `apps/dispatcher/lib/create_dispatch_screen.dart`).
Avoid `print` in new code; use `debugPrint` or the UI instead.

**Python:** `print` for CLI output in `services/graph-service/tools/` and `spike/`.
The server uses `print` only for its startup banner (`services/graph-service/src/server.py`).

## Comments

**When to comment:**
- Explain the constraint, PRD reference, or invariant the code enforces.
- Explain why a fallback exists (e.g. "the destination is still returned with
  `reachable:false`" in `services/registry-api/src/dispatch.js`).
- Do not narrate what the next line does.

**Section dividers:** Long files use banner comments:
```js
// ---------------------------------------------------------------------------
// C1/C2 — identity is never decided by the sync layer
// ---------------------------------------------------------------------------
```
Used in `packages/sync-core/test/constraints.test.js` and
`services/registry-api/test/dispatch.test.js`. Keep this style for test files.

**JSDoc:** Used for public functions and classes with `@param` and `@returns`
(`packages/sync-core/index.js`, `services/registry-api/src/dispatch.js`).
Typed with `{Type}` braces. Use `@typedef` for shape objects
(`/** @typedef {{value:*, lamport:number, siteId:string}} FieldVersion */`).

**Dart:** `///` doc comments. Use `///` on public classes and members.

## Function Design

- Keep functions small and single-purpose. Route handlers in `server.js` are
  long because they are a flat dispatch table; do not refactor that shape
  without reason.
- Options objects with destructuring defaults for constructors and factories:
  `constructor({ registry, router = null } = {})` in `services/registry-api/src/dispatch.js`,
  `createServer({ registry = ..., backendName = ..., auth = null } = {})`.
- Throw early for missing required dependencies:
  `if (!registry) throw new Error('InternalBackend requires a registry');`
- Pure functions for merge and math (`mergeField`, `TileMath.tileFor`) so they
  can be tested without I/O.

## Module Design

**Exports (JavaScript):** Named exports via `module.exports = { ... }` at the
bottom of each file. Classes and factories are exported together:
`module.exports = { DispatchBackend, InternalBackend, createBackend }`.

**Dependency direction:** `registry-api` depends on the `DispatchBackend`
interface, never on a concrete backend. Add new backends behind
`createBackend` in `services/registry-api/src/dispatch.js`. Do not change
routes or schema to accommodate a backend.

**Dependency-free core:** `packages/sync-core/index.js` must not require any
npm package. Anything it needs must come from Node built-ins.

**Barrel files:** None. Dart imports reference the concrete file.

**Identity boundary (C1/C2):** Code in the sync layer must never write identity
fields (`id`, `code`, `structure_id`, `version`). The rule is enforced in
`packages/sync-core/index.js` by `IDENTITY_FIELDS` and `IdentityMergeRefused`,
and tested in `packages/sync-core/test/constraints.test.js`. New fields that
touch identity must be added to that set, not handled ad hoc.

## Patterns to Follow When Adding Code

1. Read the module header comment first. It names the PRD section and the
   constraint IDs the module must honour.
2. Add the constraint test in the matching `test/` file before or with the code.
3. Use the existing dependency injection shape (`{ registry, router, auth }`
   options) so tests can run against `:memory:` SQLite.
4. Keep HTTP error codes snake_case and reuse existing ones before inventing new ones.
5. For Dart screens, follow the existing `*_screen.dart` layout and use the
   shared components in `apps/dispatcher/lib/components.dart` and
   `apps/dispatcher/lib/design_system.dart`.

---

*Convention analysis: 2026-11-13*
