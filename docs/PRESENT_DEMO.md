How to present / demo the current version (honest capabilities)
==============================================================
Environment state (verified on this machine):
- Node 26.12.1: yes
- Python 3.12 venv (.venv-spike): yes
- Flutter SDK (.cache/flutter/bin): YES (3.24.5) — installed by `scripts/setup-flutter.sh`
- Docker: NO (no group, no socket, no sudo for install)
- PostGIS (.pgroot/): yes
- Registry service: starts with `node`
- Dispatcher app code: tests pass (`flutter test` +2); `flutter build linux` fails (Linux desktop dependency gap); `flutter build apk` blocked (Android SDK absent per `flutter doctor`)
- Mapper app code: tests pass (`flutter test` +7); same build limits apply

What you CAN demonstrate live (one-command entry points):

1. Verified baseline (30 seconds, no network needed)
   Command: bash scripts/verify-all.sh
   Shows: 70 assertions green, 6 suites, constraint tests C1-C9.

2. Registry server (live HTTP endpoint for demo)
   Command: PORT=8090 node services/registry-api/src/server.js  (background)
   Or: node -e "const {createServer}=require('./services/registry-api/src/server'); const s=createServer(); s.listen(8090, ()=>console.log('registry on 8090'))"
   Then test with curl:
     curl -X POST http://localhost:8090/v1/grievances \
       -H "Content-Type: application/json" -H "x-role: mapper" \
       -d '{"device_hash":"demo-01","structure_code":"TEST-001","reported_location":{"lat":12.97,"lon":77.59},"photo_sha256":"demo-sha","body":"Synthetic complaint for presentation"}'
   Expected response: 201, synthetic=true, state=received, weight=0.1

3. Grievance triage transition (live)
   Command (after POST above):
     curl -X POST http://localhost:8090/v1/grievances/{id}/triage \
       -H "Content-Type: application/json" -H "x-role: reviewer" \
       -d '{"state":"corroborating","note":"Synthetic triage for demo","source":"grievance_corroborated"}'
   Expected: state updates; if weight >= 0.5, mapper task triggered (priority 1).

4. M0 regression (synthetic GPS traces, 3 minutes)
   Command: cd spike && ../.venv-spike/bin/python m0_multiseed.py
   Shows: hybrid passes corrected gate vs naive baseline.
   IMPORTANT: say "synthetic traces only — field accuracy unverified. No lane_entry_exit.gpx."

5. Grievance synthetic tests (instant)
   Command: node --test services/registry-api/test/grievance.test.js
   Shows: 7 assertions pass (synthetic labels, rate limits, weights, state machine, corroboration threshold, offset > 25m, exclusion of real-world validation).

What to say during presentation (explicit, no invented claims):
- "M0-M6 verified by 70 automated assertions. M7 grievance workflow implemented with synthetic data. M8 deferred items clearly listed in docs/M8_LOCAL_STATUS.md."
- "PRD §6.2 superseded by M0 measurement — contradiction documented in ADR.md; PRD unchanged."
- "Grievance endpoints carry synthetic=true. No real settlement PII. Rate limits synthetic (in-memory). No real imagery integrated."
- "Flutter SDK installed locally (3.24.5, no root). Dispatcher (+2) and mapper (+7) tests verified green. Desktop build (`flutter build linux`) fails due to Linux desktop dependency gap (not SDK absence). Mobile APK blocked by Android SDK absence (`flutter doctor` confirms)."
- "GPS capture blocked — synthetic only. 100-structure dry run deferred."

What you CANNOT demonstrate honestly on this machine:
- Live dispatcher/mapper Flutter desktop app (`flutter build linux` fails; `flutter run -d linux` blocked by Linux desktop dependency gap)
- Mobile APK build (`flutter doctor`: [✗] Android SDK not installed)
- Docker-based services (`make up`) — Docker not installed, no sudo for install
- Real GPS trace capture
- Live cluster load test
- Real imagery change detection for C4/C9

Quick demo script (copy-paste for presentation):

  # 1. Show verified baseline
  bash scripts/verify-all.sh

  # 2. Start registry (background)
  PORT=8090 node services/registry-api/src/server.js &

  # 3. Submit synthetic grievance (visible response with synthetic=true)
  curl -s -X POST http://localhost:8090/v1/grievances \
    -H "Content-Type: application/json" -H "x-role: mapper" \
    -d '{"device_hash":"demo-01","structure_code":"TEST-001","reported_location":{"lat":12.97,"lon":77.59},"body":"Synthetic complaint for presentation"}' | head -c 500

  # 4. Show M0 regression output
  echo "Synthetic M0 regression results:"
  head -15 spike/M0_RESULTS.md

  # 5. Stop registry
  kill %1 || true
