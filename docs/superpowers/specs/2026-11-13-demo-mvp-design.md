# Demo MVP — end-to-end dispatch loop

**Date:** 2026-11-13 · **Size:** small change set (4 fixes + a demo script)

## Intent

Mentor check-in, graded on demonstrated progress. Show one structure travel the
whole PRD §6.8 loop live: mapper walks + pins on phone → sync → structure gets
a code → simulated call → dispatcher looks up code → route drawn → responder
marks "failed" → re-survey task appears.

Every fix lands in the real code path, so the MVP is the production shape, not
a demo fork. Niche edge cases may stay broken.

## Goals / non-goals / anti-goals

- **Goal:** the loop above runs on a fresh SQLite server + the Flutter app.
- **Non-goals:** dedup review screen, photo capture, imagery change detection,
  footprint bootstrap, role-gating gaps, multi-zone support.
- **Anti-goal:** demo-only shortcuts (hard-coded data, mock responses) that
  would have to be ripped out later.

## Approaches

| | Approach | Trade-off |
|---|---|---|
| **A (picked)** | Fix the four breaks in the real code paths, plus a demo runbook script | ~4 small changes; nothing thrown away |
| B | Seed script with pre-made structures/zone/graph; dispatcher side only | Fastest, but skips mapping (the "living registry" claim) and is throwaway |
| C | A + dedup-review screen + photo capture | More to show, ~2× work, more live-demo risk |

User picked A.

## Decisions

1. **Code issuance (user decision).** On sync, a new structure with **no**
   dedup candidate within its threshold gets a code immediately
   (`issueCode` with reviewer `system:no_nearby_structure`). A structure **with**
   a candidate still waits for a human decision. Matches PRD §6.1; narrows
   internal rule C1 to "any possible duplicate needs a human". Push result
   returns the `code` so the app can show it.
2. **Zones from config (my call).** Registry reads `ZONES_FILE` (JSON array of
   `{code, name, lat, lon, radius_m, dispatch_enabled}`) at startup and upserts
   by `code`. A checked-in `config/zones.campus.json` holds the campus zone.
   Real deployments swap the file, no code change.
3. **Service records ride the structure op (my call).** The app puts
   `services: [...]` inside the `local_structure/create` payload instead of
   separate `local_service` ops (which reference a local id the server never
   sees). Server inserts them into `structure_service` in the same op.
4. **Graph service speaks lat/lon (my call).**
   - `POST /v1/graph/rebuild` accepts `{source: "registry"}`: fetches
     `REGISTRY_URL/v1/breadcrumbs`, groups by `trace_id`, builds. Raw `traces`
     input stays for tests/spike tools.
   - Points are projected to local metres (equirectangular around the first
     point; origin stored on the graph). `route` projects `from`/`to` with the
     same origin, so the 25 m snap is real metres.
   - Route legs gain `from`/`to` `{lat, lon}` so the app can draw the path.
5. **Responder start point (my call).** Lookup screen sends a configurable
   staging point (Settings, defaulting to the zone centre) as
   `responder_location` through `/v1/dispatch/lookup`, instead of calling the
   graph service directly with a hard-coded coordinate. One route path, via the
   registry's `GRAPH_URL`.
6. **Demo runbook.** `scripts/demo.sh` starts registry (with `ZONES_FILE`,
   `GRAPH_URL`) and graph service, then triggers a rebuild after the mapper
   syncs. `docs/PRESENT_DEMO.md` updated with the click-path.

## Constraints

- No new dependencies. Registry stays on `node:sqlite`; graph service on
  numpy/scipy.
- Existing tests keep passing; each fix gets one test at its seam.
- Graph quality depends on input: record 3–4 overlapping walks of the demo
  route beforehand.

## Left to the builder

Exact JSON shapes beyond the above, projection helper placement, how the app
surfaces the new code after sync (pull already updates local codes).
