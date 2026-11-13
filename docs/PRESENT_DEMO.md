# Demo: the living-registry loop (PRD §6.8)

One structure travels the whole loop live:

**mapper walks + pins on the phone → sync → structure gets a code → simulated call → dispatcher looks up the code → route drawn → responder marks "failed" → re-survey task appears.**

## Before the day

1. **Set the zone to your campus.** Edit `config/zones.campus.json`: `lat`/`lon` = campus centre, `radius_m` = how far out dispatch is allowed. Structures outside it are refused with `outside_mapped_zone`.
2. **Check the loop works on this machine** (throwaway in-memory instances, touches nothing):
   ```bash
   scripts/demo.sh selftest
   ```
   Every line must say `PASS`.
3. **Start the services** (laptop):
   ```bash
   scripts/demo.sh start
   ```
   Phone and laptop on the same network. In the app: Settings → Registry API Base URL = `http://<laptop LAN IP>:8090`. Set *Responder start latitude/longitude* to where responders set off from (default: the zone centre).
4. **Record the walks.** In the mapper app (Field tab), record **3–4 overlapping walks** of the route you will show — from the responder start point to the structure you will pin. One walk gives a patchy graph. Sync after each walk.
5. **Build the graph:**
   ```bash
   scripts/demo.sh rebuild
   ```
   `insufficient_breadcrumbs` means the walks did not sync — check the app's sync count.

## One laptop, no phone (Linux build)

Use this when there is no Android build. Everything runs on one Linux machine, and you switch roles with **More → Sign out**.

1. Get the app: download `dispatcher-linux-<tag>.tar.gz` from the GitHub Release, then `tar -xzf dispatcher-linux-<tag>.tar.gz` (needs GTK3: `sudo apt install libgtk-3-0`).
2. `bash scripts/demo.sh start`, then **`bash scripts/demo.sh seed`**. This loads three pre-recorded walks (standing in for the phone's GPS walks) and builds the graph. It prints the coordinates to pin the structure at.
3. `./bundle/dispatcher`. In Settings, Registry API Base URL = `http://127.0.0.1:8090`. The responder start stays at the default (the zone centre).
4. Run the live steps below. In step 1, sign in as **mapper**, type the printed latitude/longitude into the capture form (the desktop has no GPS, so "use current location" says to enter coordinates by hand), save, and Sync.

Say: "in the field the phone records these walks and the pin location; here they are pre-loaded so we can show the loop on one screen."

## Live (about 3 minutes)

| Step | Who | Do | Show |
|---|---|---|---|
| 1 | Mapper | Pin a structure on the walked route, add a water service, tap Sync | The pin now shows its code (`SLR-…`) — issued at sync because nothing is nearby |
| 2 | Caller | Calls tab → log an emergency with that code | The call in the list |
| 3 | Dispatcher | Lookup → enter the code | Destination, zone, and the route drawn on the map with distance and "inferred" legs |
| 4 | Dispatcher | Dispatch → mark **Failed** | Outcome recorded |
| 5 | Anyone | `curl -s http://127.0.0.1:8090/v1/tasks` | A priority-1 `dispatch_failure` task for that structure — the fast signal (PRD §6.4) |

Say: "the registry corrected itself from the field, with no manual resurvey scheduled."

Pin a second structure within ~12 m of the first to show the other branch: it syncs as `dedup_required` and gets **no code** until a reviewer decides (PRD §6.1).

## After

```bash
scripts/demo.sh stop
```
`demo.db` keeps the session's data; delete it to start clean.

## What to say honestly

- Campus stands in for a settlement (PRD §3). GPS walks are real; nothing is validated on a real settlement.
- Routes are **inferred** from walks and flagged as such until a mapper or responder confirms them (C8).
- Not in this demo: photo capture, the dedup review screen, imagery change detection, footprint bootstrap.

## Grievance channel (curl, synthetic)

```bash
curl -s -X POST http://127.0.0.1:8090/v1/grievances \
  -H "Content-Type: application/json" \
  -d '{"device_hash":"demo-01","structure_code":"SLR-C41001","reported_location":{"lat":12.97,"lon":77.59},"body":"Synthetic complaint for presentation"}'
```
Expected: `201`, `state: received`, `weight: 0.1`. A report more than 25 m from the registered structure opens a dedup-review task instead of asserting anything.

Triage (note: this endpoint has no role check yet — a known gap, not for the demo script):
```bash
curl -s -X POST http://127.0.0.1:8090/v1/grievances/<id>/triage \
  -H "Content-Type: application/json" \
  -d '{"state":"corroborating","source":"grievance_corroborated"}'
```
