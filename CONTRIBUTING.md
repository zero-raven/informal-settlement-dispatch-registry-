# Contributing

Setup, run and test commands are in the [README](README.md). This file covers how to make a change.

## Workflow

1. Branch from `main`: `feat/<short-name>`, `fix/<short-name>` or `docs/<short-name>`.
2. Make the change **with a test** (see below). Run `bash scripts/verify-all.sh` before you push.
3. Open a PR into `main`. CI ([`ci.yml`](.github/workflows/ci.yml)) must be green: Node, Python, the demo-loop selftest and Flutter analyze/test.
4. Releases: push a `v*` tag to build the APK and Linux binary.

Commit messages follow the style already in `git log`: `feat(registry): …`, `fix(dispatch): …`, `docs: …`, `chore: …`, `ci: …`. The scope is the area touched (`registry`, `graph`, `app`, `sync`, `dispatch`).

## Where things go

| Change | Code | Test |
|---|---|---|
| New registry endpoint | Route in `services/registry-api/src/server.js`, logic in the matching module (`registry.js`, `dispatch.js`, `feedback.js`, `disclosure.js`) | `services/registry-api/test/*.test.js` (`node:test`). HTTP-level tests use `createServer()`, see `http-e2e.test.js` |
| Schema change | `Registry#applySchema()` in `registry.js` (SQLite runtime) **and** `services/registry-api/migrations/*.sql` (Postgres) | `registry.test.js`; `scripts/registry-schema-test.sh` for Postgres |
| Sync / merge rule | `packages/sync-core/index.js` **and** its mirror in `registry.js` (`MERGEABLE`, `IDENTITY_FIELDS`). They must agree | `packages/sync-core/test/` |
| Graph or routing | `services/graph-service/src/` (`hybrid.py` build, `routing.py` A*, `geo.py` lat/lon) | `services/graph-service/test/` (pytest) |
| App screen or behaviour | `apps/dispatcher/lib/`. Offline store, GPS and sync are in `lib/core/` | `apps/dispatcher/test/` (`flutter_test`; the local store tests use `sqflite_common_ffi`) |
| Demo flow | `scripts/demo.sh`, `scripts/demo-selftest.js`, `docs/PRESENT_DEMO.md` | `bash scripts/demo.sh selftest` |
| Dispatch zones | `config/zones.campus.json` | Server refuses to start if invalid |

## Rules that reviews check

These come from the PRD and are enforced by tests. A change that weakens one needs an ADR entry in `.planning/codebase/ADR.md`.

- **C1:** only `Registry#issueCode` mints a code, and every caller names who decided (a reviewer, or `system:no_nearby_structure`).
- **C2:** no automatic merge of possible duplicates. Identity fields are never CRDT-merged.
- **C3:** registry-api never reads resident identity. Only consent-api holds it.
- **C7:** dispatch only inside an enabled zone.
- **C8:** inference (graph edges, imagery) is written as `candidate`, never over ground truth.
- No PII in the registry. Service data is role-gated (`disclosure.js`).

## Tests

- Write the test first and watch it fail. Each test should name what the PRD requires, like the existing ones (`'C2: a second pin near an existing structure creates a candidate, not a merge'`).
- Use real code, not mocks. The registry runs on in-memory SQLite (`new Registry(':memory:')`), so tests need no setup.
- Tests that start servers must stop them even when they fail (`try/finally`); see `services/graph-service/test/test_e2e_dispatch.py`.

## Debugging

- Registry: `DB_PATH=./debug.db npm start --prefix services/registry-api`, then inspect the file with any SQLite browser. `node --inspect src/server.js` attaches a debugger.
- Graph: `GET /v1/graph/health` shows the version and size; `GET /v1/graph/segments` dumps the edges.
- A single Node test: `node --test --test-name-pattern="C2" services/registry-api/test/registry.test.js`.
- A single pytest: `.venv/bin/python -m pytest services/graph-service/test/test_geo.py -k far -v`.
- More symptoms and causes are in the README's Debugging table.

## Housekeeping

- Commit lockfiles (`package-lock.json`, `pubspec.lock`). Don't commit `.venv/`, `node_modules/`, `demo.db`, `data/` or downloaded tiles. `.gitignore` covers these.
- Line endings are normalised to LF by `.gitattributes`, so shell scripts work from a Windows clone.
- Never commit real secrets or real resident data. The demo accounts and dev secret are for local use only. Set `AUTH_SECRET` and `AUTH_USERS_JSON` anywhere else.
