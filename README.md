# Informal-Settlement Address & Emergency Dispatch Registry

Offline-first registry assigning stable IDs to un-addressed structures, building a
routable footpath graph, and feeding emergency dispatch — with resident identity
kept structurally separate from location data.

Design documents are in `docs/`. Implementation status is tracked in
`docs/development-plan.md`.

## Verify everything

```bash
./scripts/setup-postgis.sh --verify   # once: installs PostGIS unprivileged
./scripts/setup-flutter.sh            # once: installs the Flutter SDK locally
./scripts/verify-all.sh               # ~25 s, 70 assertions, 6 suites
```

No root and no Docker required. `setup-postgis.sh` fetches the Arch package via
`pacman -Sp` and extracts it into `.pgroot/`; `setup-flutter.sh` fetches the
official stable tarball into `.cache/`. Both are gitignored.

## What each suite proves

| Suite | Proves | Constraint |
|---|---|---|
| `packages/sync-core` (19 tests) | field-level CRDT merge, outbox, idempotency, opportunistic sync; airplane-mode acceptance | C1, C2, C4, C5 |
| `scripts/registry-schema-test.sh` (18) | migrations apply; inference cannot overwrite ground truth; a code cannot be minted without a prior survey | C1, C2, C8, PRD 6.1 |
| `scripts/c3-isolation-test.sh` (8) | `registry_api` is refused `identity_db`; no cross-DB foreign key | C3 |
| `scripts/postgis-verify.sh` (18) | real PostGIS typmods, gist indexes, `ST_Contains` zone containment, `tstzrange` | C7, C8, PRD 6.6 |
| `apps/mapper` (7 tests) | capture works with no network; survives restart; UI capture commits offline | C4, PRD 6.1, 6.6 |
| `spike/m0_multiseed.py` | 4 path-graph approaches re-scored over 6 seeds | C9 |

Each is a constraint test, not a smoke test: it asserts something the PRD
requires and fails if the implementation drifts.

## M0 path-graph spike

```bash
cd spike && ./run.sh quick    # ~40 s
./run.sh                       # ~3 min, adds the GPS-noise sweep
```

Result: the PRD's proposed k-means+Delaunay **failed** the gate; a hybrid was
adopted. Full analysis in `spike/M0_RESULTS.md`. Synthetic traces only — no field
accuracy is claimed.

## Mapper app

```bash
export PATH="$PWD/.cache/flutter/bin:$PATH"
cd apps/mapper
flutter run -d linux
flutter test
flutter build linux --release
```

Capture writes locally and never awaits the network. Sync runs only when
connectivity appears.

## Layout

```
docs/            architecture, database, api, development plan
services/        registry-api and consent-api migrations (separate DBs)
packages/        sync-core — CRDT, outbox, idempotency, cursor
apps/mapper/     Flutter offline-first mapper app
spike/           M0 path-graph feasibility spike + regression harness
scripts/         verification suites and unprivileged installers
```

## Constraints that must not be weakened

1. Structure identity is never assigned by AI.
2. Possible duplicates require human review — no automated merge path exists.
3. Resident identity is a separate database with separate credentials.
4. Offline operation is required; sync is opportunistic.
5. AI scope is limited to path-graph clustering, footprint bootstrap,
   change-detection prioritisation, and low-literacy capture assistance.
6. Dispatch operates only inside the pilot mapped zone.
7. Inference never silently overwrites ground truth.
8. The path-graph algorithm is chosen by measurement, not assumption.

Constraints 1, 2, 3, 6, 7 and 8 are enforced by database permissions and triggers
rather than by convention — see `docs/architecture.md` §5.10 and §5.11.
