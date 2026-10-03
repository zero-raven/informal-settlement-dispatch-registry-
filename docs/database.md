# Database Schema

## 0. Database Topology

Three physically separated stores, per PRD §4 (identity must remain separate from structural data):

| Store | Engine | Contents | PII |
|-------|--------|----------|-----|
| `registry_db` | PostgreSQL 16 + PostGIS 3.4 | Structures, services, grievances, verification events, path-graph topology, mappers | No |
| `identity_db` | PostgreSQL 16 (separate instance + separate credentials) | Consent vault, resident identity, linkage | **Yes** |
| `graph_cache` | Redis 7 | Materialized routing graph, adjacency, turn penalties | No |

Hard rule: the structural service has **no network route or credentials** to `identity_db`. Identity is exposed to dispatch only through a narrow, audited resolver endpoint that returns an opaque "occupant context present/absent" plus consented fields.

---

## 1. registry_db

### 1.1 Enumerations

```sql
-- §6.1 RESOLVED. A structure is: "A physically distinguishable residential
-- unit that can be assigned a unique destination for mapping and emergency
-- dispatch." These enum values encode the classification rules.
CREATE TYPE structure_type AS ENUM (
  'standalone_dwelling',            -- standalone dwelling = 1 structure
  'shared_wall_dwelling',           -- shares a wall; separate iff independent entrances
  'multi_household_single_entry',   -- several households, one common entrance = 1 structure
  'compound_dwelling',              -- compound with independently accessible dwellings
  'temporary_shelter',              -- counts iff it functions as an independent destination
  'non_residential'                 -- navigation/context only; MUST carry an explicit type
);

-- §6.6 RESOLVED. Service data is sensitive operational data, not public.
CREATE TYPE disclosure_policy AS ENUM (
  'full',              -- role-gated, exact values
  'aggregate_only',    -- coarsened: bucketed counts, rounded hours, no exact coordinates
  'redacted'           -- aggregate statistics only, no per-structure read
);

CREATE TYPE structure_status AS ENUM (
  'candidate',      -- bootstrapped from footprint dataset, unverified
  'surveyed',       -- mapper confirmed on the ground
  'verified',       -- corroborated beyond a single visit
  'disputed',       -- in dedup review
  'demolished',     -- confirmed gone
  'unreachable'     -- path to structure not currently routable
);

CREATE TYPE verification_method AS ENUM (
  'footprint_bootstrap',
  'mapper_survey',
  'resident_report',
  'dispatch_feedback',
  'imagery_diff',
  'dedup_review',
  'grievance_corroborated'
);

CREATE TYPE service_type AS ENUM (
  'water', 'electricity', 'sanitation', 'waste', 'internet', 'road_access', 'drainage'
);

CREATE TYPE service_source AS ENUM (
  'utility', 'informal_tap', 'shared_private', 'community', 'none', 'unknown'
);

CREATE TYPE quality_rating AS ENUM ('good', 'fair', 'poor', 'unknown');

CREATE TYPE grievance_state AS ENUM (
  'received', 'triaged', 'corroborating', 'resolved', 'rejected'
);

CREATE TYPE sync_op AS ENUM ('create', 'update', 'delete');

-- §Ground truth vs inference. Every asserted value carries its evidence class.
-- Inference NEVER silently overwrites ground truth (enforced by trigger, §1.5).
CREATE TYPE evidence_class AS ENUM (
  'ground_truth',   -- mapper verification, responder observation, resident report
  'inference'       -- GPS trace clustering, imagery change detection, route
                     -- confidence, duplicate candidates
);

-- The pipeline: Inference → Candidate change → Verification → Ground-truth update
CREATE TYPE assertion_state AS ENUM (
  'asserted',       -- current value, carries evidence_class
  'candidate',      -- inference pending verification; NOT authoritative
  'superseded'      -- was authoritative, replaced by a newer ground truth
);
```

### 1.2 `structure`

The core entity. Carries no PII and no location-derived identity.

```sql
CREATE TABLE structure (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code              text UNIQUE,                -- human-facing, assigned ONLY server-side, non-derivable
  status            structure_status NOT NULL DEFAULT 'candidate',
  structure_type    structure_type NOT NULL DEFAULT 'standalone_dwelling',
  non_residential_subtype text,                  -- REQUIRED when structure_type='non_residential'
  footprint         geometry(Polygon, 4326),   -- may be null until surveyed
  centroid          geometry(Point, 4326) NOT NULL,
  access_point      geometry(Point, 4326),     -- nearest routable node, set by graph service
  -- §6.1: the definition turns on independent destination/entrances, so the
  -- entrance is first-class geometry, not a note field.
  entrance_geom     geometry(Point, 4326),
  entrance_independent boolean,                 -- §6.1 discriminator for shared-wall cases
  compound_root_id  uuid REFERENCES structure(id),  -- self-ref: compound parent for dwellings within
  floors_estimated  smallint,
  material_primary  text,
  occupancy_estimate smallint,                 -- structural/aggregate only, never identity
  is_shared_wall    boolean,                    -- kept per §6.1; TRUE when wall shared w/ another structure
  shares_wall_with  uuid REFERENCES structure(id), -- symmetric, set by reviewer/decision
  disclosure_policy disclosure_policy NOT NULL DEFAULT 'aggregate_only', -- §6.6
  dedup_threshold_m numeric(6,2) NOT NULL DEFAULT 12.00, -- §6.1: CANDIDATE-GENERATION
                                                  -- threshold only, NOT the definition of a structure
  first_seen_at     timestamptz NOT NULL DEFAULT now(),
  last_verified_at  timestamptz,
  verification_src  verification_method,
  version           integer NOT NULL DEFAULT 1, -- optimistic concurrency for sync
  created_by        uuid NOT NULL,              -- mapper id
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz,                -- soft delete; never hard-deleted in field
  CONSTRAINT verified_needs_source CHECK (
    status <> 'verified' OR (last_verified_at IS NOT NULL AND verification_src IS NOT NULL)
  ),
  CONSTRAINT non_residential_needs_subtype CHECK (
    structure_type <> 'non_residential' OR non_residential_subtype IS NOT NULL
  )
);

CREATE INDEX structure_centroid_gix ON structure USING gist (centroid);
CREATE INDEX structure_footprint_gix ON structure USING gist (footprint) WHERE footprint IS NOT NULL;
CREATE INDEX structure_status_idx ON structure (status) WHERE deleted_at IS NULL;
CREATE INDEX structure_lastverified_idx ON structure (last_verified_at NULLS FIRST);
```

**`code` is never assigned by AI and never by the client.** It is generated server-side by a deterministic-but-opaque sequence only *after* dedup review clears the structure. See §1.6.

### 1.3 `structure_service`

Structured per-service records, not binary flags (PRD §6.6).

```sql
CREATE TABLE structure_service (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  structure_id     uuid NOT NULL REFERENCES structure(id) ON DELETE CASCADE,
  service_type     service_type NOT NULL,
  source           service_source NOT NULL DEFAULT 'unknown',
  supply_hours     tstzrange,                    -- e.g. 06:00-10:00, 18:00-22:00
  quality          quality_rating NOT NULL DEFAULT 'unknown',
  shared_with_count smallint NOT NULL DEFAULT 0 CHECK (shared_with_count >= 0),
  last_verified_at timestamptz,
  verification_src verification_method,
  still_true_checked_at timestamptz,            -- cheap re-check marker (§6.6)
  field_version    integer NOT NULL DEFAULT 1,   -- CRDT-merged per field on sync
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (structure_id, service_type)
);

CREATE INDEX structure_service_reverify_idx
  ON structure_service (last_verified_at NULLS FIRST);
```

**§6.6 DECIDED.** These rows carry the same sensitivity class as any structural operational data: role-based access, `aggregate_only` by default, no public or resident-facing exposure. The adopted policy is *"Structure-level service information is sensitive operational data and is not publicly exposed. Access is role-based; aggregate service statistics may be exposed where appropriate."*

### 1.4 `dedup_candidate`

Human review queue. No auto-merge path exists in code.

```sql
CREATE TABLE dedup_candidate (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  structure_a      uuid NOT NULL REFERENCES structure(id),  -- already-synced
  structure_b      uuid NOT NULL REFERENCES structure(id),  -- newly arrived
  -- §6.1: proximity ALONE never decides. Multiple independent signals are
  -- recorded so a human reviews evidence, not a single radius.
  distance_m       numeric(8,2) NOT NULL,        -- GPS centroid proximity
  entrance_dist_m  numeric(8,2),                 -- entrance proximity (separate destination test)
  iou              numeric(5,4),                 -- footprint overlap
  wall_shared      boolean NOT NULL DEFAULT false, -- shared-wall evidence
  photo_similarity real,                         -- photo/visual evidence
  mapper_conflict  boolean NOT NULL DEFAULT false,-- same mapper flags both as one
  score            numeric(5,4) NOT NULL,        -- RANKING ONLY, never a decision
  signals          jsonb NOT NULL DEFAULT '{}',  -- full evidence bundle for the reviewer
  state            text NOT NULL DEFAULT 'open'
                     CHECK (state IN ('open','in_review','merged','distinct','deferred')),
  reviewer_id      uuid,
  reviewed_at      timestamptz,
  decision_note    text,
  created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX dedup_open_idx ON dedup_candidate (score DESC) WHERE state = 'open';
CREATE INDEX dedup_entrance_idx ON dedup_candidate (entrance_dist_m) WHERE state = 'open';
```

**§6.1 classification applied to dedup outcome.** Two nearby pins are *not* automatically distinct and *not* automatically the same. The reviewer applies the definition:

- Same building, one common entrance → **1 structure** (`multi_household_single_entry`) → merge
- Shared wall, independent entrances → **2 structures** → distinct
- Compound with independently accessible dwellings → **multiple structures** → distinct, and each child gets `compound_root_id`
- Temporary shelter with independent destination → counts → distinct

`dedup_threshold_m` triggers *candidate generation* only. Passing it means a human looks; it never means "same building". A single radius cannot express "shares a wall but separate entrances", which is exactly why the definition had to be written first.

### 1.5 `assertion` — ground truth vs inference

The architectural principle made mechanical. Every value a system asserts about the world is a row here, tagged with its evidence class. Nothing outside this table is authoritative.

```sql
CREATE TABLE assertion (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_table   text NOT NULL,          -- 'structure', 'structure_service', 'walk_segment'
  entity_id      uuid NOT NULL,
  field          text NOT NULL,          -- 'centroid', 'entrance_geom', 'quality', ...
  value          jsonb NOT NULL,
  evidence_class evidence_class NOT NULL,
  state          assertion_state NOT NULL DEFAULT 'asserted',
  source         verification_method NOT NULL,
  -- ground-truth provenance; NULL for inference rows by construction
  observed_by    text,                   -- 'mapper:…' | 'dispatch:unit-7' | 'resident:hash'
  observed_at    timestamptz,
  -- inference provenance
  produced_by    text,                   -- 'ml:pathgraph', 'imagery:job-9', 'dedup:scorer'
  produced_at    timestamptz,
  confidence     real,                   -- inference only; NULL for ground truth
  supersedes_id  uuid REFERENCES assertion(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ground_truth_needs_observer CHECK (
    evidence_class <> 'ground_truth' OR (observed_by IS NOT NULL AND observed_at IS NOT NULL)
  ),
  CONSTRAINT inference_has_no_observer CHECK (
    evidence_class <> 'inference' OR observed_by IS NULL
  ),
  CONSTRAINT inference_only_candidates CHECK (
    evidence_class <> 'inference' OR state = 'candidate'
  )
);

CREATE INDEX assertion_entity_idx ON assertion (entity_table, entity_id, field);
CREATE INDEX assertion_candidates_idx ON assertion (state, produced_at DESC) WHERE state = 'candidate';
CREATE UNIQUE INDEX assertion_current_idx ON assertion (entity_table, entity_id, field)
  WHERE state = 'asserted';
```

**The overwrite rule, enforced by trigger — not by convention:**

```sql
-- Inference may NEVER overwrite ground truth. A candidate is a separate row;
-- it becomes authoritative only via an explicit verification transaction.
CREATE OR REPLACE FUNCTION assertion_no_inference_overwrite() RETURNS trigger AS $$
BEGIN
  IF OLD.evidence_class = 'ground_truth'
     AND NEW.state = 'asserted'
     AND NEW.evidence_class = 'inference' THEN
    RAISE EXCEPTION 'inference cannot overwrite ground truth (assertion %, field %)',
      OLD.id, NEW.field;
  END IF;
  RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_assertion_no_overwrite
  BEFORE UPDATE ON assertion
  FOR EACH ROW EXECUTE FUNCTION assertion_no_inference_overwrite();
```

The pipeline is therefore literal:

```
inference (candidate row)
   │  never overwrites; state='candidate'
   ▼
candidate change  ← verification task created (mapper / responder / resident)
   │  human or field observation
   ▼
verification
   │  new row, evidence_class='ground_truth', supersedes_id set
   ▼
ground-truth update  (previous asserted row → state='superseded')
```

### 1.6 Evidence class by field

| Field | Class | Produced by |
|---|---|---|
| `structure.centroid` | ground truth | mapper verification; responder observation corrects it |
| `structure.entrance_geom` | ground truth | mapper — the §6.1 discriminator is an observation, never inferred |
| `structure.entrance_independent` | ground truth | mapper |
| `structure.structure_type` | ground truth | mapper (§6.1) |
| `structure.status` | ground truth | mapper / responder / resident report |
| `structure.footprint` | **both** | bootstrap = candidate; mapper survey = ground truth |
| `structure_service.*` | ground truth | mapper survey; `dispatch_feedback` outranks resident report until corroborated |
| `dedup_candidate` (whole row) | **inference** | proximity/IoU/entrance/photo/wall scoring — always a candidate |
| `walk_segment` geometry | **inference** | trace clustering — always a candidate until a mapper walks it |
| `walk_segment.passable` | ground truth once reviewed | `POST /graph/segments/{id}/review` |
| `walk_segment.confidence` | inference | support count — never authoritative |
| `zone_priority.score` | inference | imagery diff — orders visits only |
| `dedup.photo_similarity` | inference | never decides; a reviewer does |
| Any AI-proposed field value | inference | proposed for confirmation; never auto-applied |

Footprint bootstrapping is the instructive case: the same logical field is `candidate` when it comes from an open dataset and `ground_truth` only once a mapper confirms it. That is why bootstrapped pins enter as `status='candidate'` — not because the model is distrusted in general, but because a specific field has not yet been observed by a person.

### 1.7 `verification_event`

Append-only audit trail feeding the two-speed re-verification model (PRD §6.4).

```sql
CREATE TABLE verification_event (
  id            bigserial PRIMARY KEY,
  structure_id  uuid NOT NULL REFERENCES structure(id) ON DELETE CASCADE,
  trigger_kind  text NOT NULL
                  CHECK (trigger_kind IN ('fast','slow','manual','bootstrap')),
  source        verification_method NOT NULL,
  outcome       text CHECK (outcome IN ('confirmed','changed','gone','unreachable','inconclusive')),
  payload       jsonb,                            -- diff of changed fields
  actor         text NOT NULL,                    -- 'dispatch:unit-7', 'mapper:uuid', 'imagery:job'
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX verification_event_structure_idx ON verification_event (structure_id, created_at DESC);
CREATE INDEX verification_event_fast_idx ON verification_event (trigger_kind, created_at DESC)
  WHERE trigger_kind = 'fast';
```

### 1.8 `structure_code_sequence`

```sql
CREATE TABLE structure_code_sequence (
  bucket         smallint PRIMARY KEY,           -- 0..999, forms two code digits
  next_value     integer NOT NULL,
  updated_at     timestamptz NOT NULL DEFAULT now()
);
```

Code format: `SLR-<region><bucket><serial>` e.g. `SLR-C41207`.
- `C` = pilot zone constant (campus)
- `4` = mapped-zone id, not a coordinate
- `1207` = bucket + serial
No coordinates, no geohash, no hash of position.

**§6.1 consequence — codes are per-structure, not per-building.** The definition assigns one structure per independently distinguishable residential destination. A shared-wall pair with two entrances therefore receives **two codes**, and a multi-household building with one entrance receives **one**. No dwelling-level suffix is needed at this layer; the classification lives in `structure_type` and `entrance_independent`.

**Three identifiers, kept separate (§6.1):**
1. `structure.id` — internal immutable UUID. Never changes, never leaves the system as a user-facing handle.
2. `structure.code` — public short code. Format above, **provisional pending real-world usage**.
3. QR representation — a renderable encoding of (2). Derived, never an independent identifier.

**FORMAT REMAINS PROVISIONAL.** The `SLR-` shape is a placeholder pending observation of how responders actually read codes aloud over radio and write them on paper. Nothing in the system depends on the format — changing it is a code-sequence change, not a migration of identity data.

**Idempotency on revisit is structural, not derived (§6.1).** Regenerating the same structure returns the existing code because lookup is by the immutable `structure.id`, never by deriving a code from position. This is precisely why the code carries no location information: a geohash-derived code would issue a *second* code for a re-surveyed structure the moment GPS drifted a metre, which would defeat the one-code-per-destination guarantee the definition requires.

### 1.9 `grievance`

```sql
CREATE TABLE grievance (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  structure_id        uuid REFERENCES structure(id),   -- null = free-text, unresolved
  reported_geometry   geometry(Point, 4326) NOT NULL, -- geo-tagged
  photo_object_key    text,                            -- geo+photo tagged (§6.5)
  body                text,
  state               grievance_state NOT NULL DEFAULT 'received',
  weight              numeric(5,4) NOT NULL DEFAULT 0.1,
  weight_src          verification_method NOT NULL DEFAULT 'resident_report',
  offset_from_registered_m numeric(8,2),               -- cross-check vs registered location
  reporter_hash       text,                            -- salted, rotating; NOT identity
  device_hash         text NOT NULL,                   -- rate-limit key
  created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX grievance_state_idx ON grievance (state, created_at DESC);
CREATE INDEX grievance_geom_gix ON grievance USING gist (reported_geometry);
```

Weight ordering: `dispatch_feedback` (1.0) > `grievance_corroborated` (0.7) > `imagery_diff` (0.4) > `mapper_survey` (0.6) > `resident_report` (0.1). A single unverified resident report cannot outrank a dispatch-sourced update.

### 1.10 `breadcrumb` and `walk_segment`

```sql
CREATE TABLE breadcrumb (
  id          bigserial PRIMARY KEY,
  mapper_id   uuid NOT NULL,
  structure_id uuid REFERENCES structure(id),
  geom        geometry(LineString, 4326) NOT NULL,
  accuracy_m  real,
  captured_at timestamptz NOT NULL,
  device_meta jsonb
);
CREATE INDEX breadcrumb_geom_gix ON breadcrumb USING gist (geom);

CREATE TABLE walk_node (
  id        bigserial PRIMARY KEY,
  geom      geometry(Point, 4326) NOT NULL,
  kind      text NOT NULL DEFAULT 'junction'
              CHECK (kind IN ('junction','gate','stair','obstruction','structure_entrance')),
  support   real,                       -- passability score
  UNIQUE (id)
);
CREATE INDEX walk_node_geom_gix ON walk_node USING gist (geom);

CREATE TABLE walk_segment (
  id            bigserial PRIMARY KEY,
  source_node   bigint NOT NULL REFERENCES walk_node(id),
  target_node   bigint NOT NULL REFERENCES walk_node(id),
  geom          geometry(LineString, 4326) NOT NULL,
  length_m      real NOT NULL,
  -- geometry is INFERENCE until a mapper/responder walks it (candidate),
  -- then ground truth. See assertion (§1.5).
  evidence_class evidence_class NOT NULL DEFAULT 'inference',
  state         assertion_state NOT NULL DEFAULT 'candidate',
  passable      boolean,                  -- NULL until verified; inference must not assume passable
  confidence    real,                     -- inference only; never authoritative
  derivation    text NOT NULL DEFAULT 'mapmatch'
                  CHECK (derivation IN ('mapmatch','delaunay_bridge','breadcrumb','dbscan','nearest_neighbor','manual','bootstrap')),
  -- which spike-candidate algorithm produced this, for M0 comparison traceability
  algorithm     text,
  build_version integer NOT NULL
);
CREATE INDEX walk_segment_geom_gix ON walk_segment USING gist (geom);
CREATE INDEX walk_segment_candidates_idx ON walk_segment (state) WHERE state = 'candidate';
```

**Algorithm DECIDED by the M0 spike — k-means+Delaunay FAILED.** Measured over 6 seeds against ground truth: it regressed destination reachability (0.782 vs baseline 1.000) and routing success (0.818 vs 1.000), because a fixed seed count spreads seeds across empty space and Delaunay bridges non-adjacent seeds across voids. Full results: `spike/M0_RESULTS.md`.

The adopted approach is a **hybrid**: `mapmatch` (backbone — best measured F1 0.668, usable-route 0.688, full reach), with `delaunay_bridge` restricted to proximity-tested, length-capped gap-bridging edges, plus adaptive density-based seeding. `algorithm` records provenance per segment so any routing result traces to the method and build version that produced it. `dbscan` and `nearest_neighbor` remain in the enum for comparison rebuilds and regression testing.

Note on metrics: **destination reach is not a discriminator.** The naive baseline reaches 100% of destinations while 96% of its routes traverse non-path geometry. Production must expose route confidence rather than a bare reachability boolean.

### 1.11 `zone` and mapped-zone enforcement

```sql
CREATE TABLE zone (
  id          serial PRIMARY KEY,
  code        text UNIQUE NOT NULL,
  name        text NOT NULL,
  boundary    geometry(MultiPolygon, 4326) NOT NULL,
  dispatch_enabled boolean NOT NULL DEFAULT false
);
```

Dispatch endpoints reject any structure whose `centroid` is not inside an enabled zone. This is the PRD §3 constraint ("dispatch functions only inside mapped zone") enforced at the data layer, not only in the app.

### 1.12 `app_user`, `mapper`, `audit_log`

```sql
CREATE TABLE app_user (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email      citext UNIQUE NOT NULL,
  role       text NOT NULL CHECK (role IN ('mapper','dispatcher','reviewer','admin')),
  active     boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE mapper_profile (
  user_id        uuid PRIMARY KEY REFERENCES app_user(id),
  last_sync_at   timestamptz,
  device_id      text,
  device_pubkey  bytea
);

CREATE TABLE sync_receipt (          -- idempotency at the boundary
  client_op_id  uuid PRIMARY KEY,
  client_seq    bigint NOT NULL,
  mapper_id     uuid NOT NULL,
  entity_table  text NOT NULL,
  entity_id     uuid NOT NULL,
  server_version integer NOT NULL,
  received_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE audit_log (
  id         bigserial PRIMARY KEY,
  actor      text NOT NULL,
  action     text NOT NULL,
  target     text NOT NULL,
  meta       jsonb,
  at         timestamptz NOT NULL DEFAULT now()
);
```

### 1.13 `zone_priority` — change-detection output

Imagery diffing produces **candidates**, never updates. This table is the only thing the change detector writes, and it has no foreign key to `structure` by design.

```sql
CREATE TABLE zone_priority (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  zone_code     text NOT NULL REFERENCES zone(code),
  score         real NOT NULL,                 -- INFERENCE: orders visits, decides nothing
  evidence_class evidence_class NOT NULL DEFAULT 'inference',
  state         assertion_state NOT NULL DEFAULT 'candidate',
  signal        text NOT NULL CHECK (signal IN ('imagery_diff','complaint_cluster','coverage_gap')),
  structures_flagged integer NOT NULL DEFAULT 0,
  last_imagery_at    date,
  recommended_window_days integer,
  produced_by   text NOT NULL,                 -- 'imagery:job-9'
  produced_at   timestamptz NOT NULL DEFAULT now(),
  superseded_by uuid REFERENCES zone_priority(id)
);
```

A `score` here **cannot** alter a structure's status, issue a code, or resolve identity. It reorders a mapper's visit list and nothing else. Verified in CI: the change-detector's database role has no `UPDATE` grant on `structure`.

---

### 1.14 Aggregate service-statistics view (§6.6)

The only service-data surface reachable by a reporting consumer. No per-structure rows, no codes, no coordinates — and structurally unable to produce them.
```sql
CREATE VIEW v_zone_service_stats AS
SELECT z.code                                        AS zone_code,
       count(DISTINCT s.id)                          AS structures_counted,
       s_service.service_type,
       count(*) FILTER (
         WHERE s_service.source NOT IN ('none','unknown')
       )                                             AS connected_count,
       round(
         count(*) FILTER (
           WHERE s_service.source NOT IN ('none','unknown')
         )::numeric / greatest(count(*), 1), 3)      AS share
FROM zone z
JOIN structure s ON ST_Contains(z.boundary, s.centroid)
LEFT JOIN structure_service s_service ON s_service.structure_id = s.id
WHERE s.deleted_at IS NULL
GROUP BY z.code, s_service.service_type;
```

**No path from this view to an individual structure.** `zone_code` and `service_type` are the only projected dimensions — there is no `structure_id`, no `code`, no geometry. A reporting consumer physically cannot iterate this view into per-structure rows, which is the property §6.6's "aggregate data only" requires. The per-structure read path (`GET /v1/structures/{code}/services`) is separately role-gated.

---

## 2. identity_db (separate instance)

Reachable only by the consent service. No joins with `registry_db` are possible; linkage is by opaque `structure_code` text resolved at read time through an audited broker.

```sql
CREATE TABLE resident (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  display_alias text,                       -- pseudonymous; real name is optional and encrypted
  enc_name      bytea,
  enc_phone     bytea,
  enc_alt_contact bytea,
  created_at    timestamptz NOT NULL DEFAULT now(),
  erased_at     timestamptz                       -- right-to-be-forgotten sets, never DELETEs silently
);

CREATE TABLE consent (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  resident_id   uuid NOT NULL REFERENCES resident(id) ON DELETE CASCADE,
  scope         text NOT NULL CHECK (scope IN (
                  'store_identity', 'link_to_structure', 'share_on_dispatch', 'receive_notification'
                )),
  granted       boolean NOT NULL,
  granted_at    timestamptz,
  revoked_at    timestamptz,
  policy_version text NOT NULL
);
CREATE INDEX consent_active_idx ON consent (resident_id, scope) WHERE granted AND revoked_at IS NULL;

CREATE TABLE structure_link (               -- only rows with active consent 'link_to_structure'
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  resident_id  uuid NOT NULL REFERENCES resident(id) ON DELETE CASCADE,
  structure_code text NOT NULL,
  consent_id   uuid NOT NULL REFERENCES consent(id),
  created_at   timestamptz NOT NULL DEFAULT now()
);
```

No foreign key from `structure_link` to `registry_db.structure`. If a structure code is ever reassigned by a dedup merge, the link breaks safely rather than silently repointing a resident to a different building. Breaks are reconciled by an explicit job that notifies the resident.

Dispatch reads: `GET /dispatch/{code}/occupant-context` returns `{"context_present": bool, "fields": [...]}` — empty list when consent absent. Absence is the default response, not an error.

---

## 3. Client-side SQLite (offline cache)

Same logical entities, subset of columns, plus sync metadata. Held in the mobile app; full copy of the mapped zone is pre-seeded so the field is usable with zero connectivity.

```sql
CREATE TABLE local_structure (
  local_id       TEXT PRIMARY KEY,        -- client-generated UUID
  server_id      TEXT,
  code           TEXT,
  status         TEXT,
  lat            REAL NOT NULL,
  lon            REAL NOT NULL,
  footprint_geojson TEXT,
  -- field-level CRDT metadata (confirmed structures only)
  field_clock    TEXT,                    -- per-field version vector, base64
  dirty          INTEGER NOT NULL DEFAULT 0,
  last_pulled_at INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE local_field_meta (            -- CRDT bookkeeping, one row per field
  local_id    TEXT NOT NULL,
  field       TEXT NOT NULL,
  lamport     INTEGER NOT NULL DEFAULT 0,
  site_id     TEXT NOT NULL,
  dirty       INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (local_id, field)
);

CREATE TABLE local_breadcrumb (
  local_id TEXT PRIMARY KEY,
  structure_local_id TEXT,
  geojson  TEXT NOT NULL,
  accuracy_m REAL,
  captured_at INTEGER NOT NULL
);

CREATE TABLE local_photo (
  local_id TEXT PRIMARY KEY,
  structure_local_id TEXT,
  path     TEXT NOT NULL,
  sha256   TEXT NOT NULL,
  uploaded INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE local_grievance (
  local_id TEXT PRIMARY KEY,
  structure_local_id TEXT,
  lat REAL, lon REAL, photo_local_id TEXT, body TEXT, uploaded INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE pending_op (
  op_id     TEXT PRIMARY KEY,              -- idempotency key
  seq       INTEGER NOT NULL,
  table_name TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  op        TEXT NOT NULL CHECK (op IN ('create','update','delete')),
  payload   TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  attempts  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX pending_op_seq_idx ON pending_op (seq);
```

---

## 4. Data Retention & Disclosure Policy

| Data | Retention | Notes |
|------|-----------|-------|
| Soft-deleted structure | Indefinite | Tombstone required for offline clients to converge |
| Breadcrumbs | 24 months, then aggregated into segments | Raw traces carry movement patterns |
| Grievance photos | 24 months | |
| `reporter_hash` salt rotation | 90 days | Breaks re-identification of serial complainants |
| Identity PII | Until consent revoked + 30-day grace | Encrypted at rest, separate key custody |
| Audit log | 7 years | Dispatch accountability |

Service-connection fields carry a per-structure `disclosure_policy` (inherited from `structure.disclosure_policy`): `full` (role-gated exact values), `aggregate_only` (coarsened — bucketed counts, rounded hours), `redacted` (aggregate statistics only, no per-structure read).

**§6.6 RESOLVED — adopted policy:** *"Structure-level service information is sensitive operational data and is not publicly exposed. Access is role-based; aggregate service statistics may be exposed where appropriate."*

Default is `aggregate_only` for every structure, and **no service data is served on any unauthenticated or resident-facing path at all** — not coarsened, not at all. `full` requires the mapper/dispatcher/admin roles and is written to `audit_log` on every read. Aggregate statistics (e.g. "62% of zone C4 structures have a water connection") are computed by a dedicated aggregate view that has no per-structure row-level path.

---

## 5. Schema verification status

M1 replaced hand-written DDL with real migrations, and the schema is now
applied and exercised against a live PostgreSQL instance by
`scripts/registry-schema-test.sh`. Results:

**Verified by execution:**

| Check | Result |
|---|---|
| Migration applies cleanly | 16 tables, 11 enums, 3 triggers |
| `inference_only_candidates` | inference row with `state='asserted'` → CHECK violation |
| `inference_has_no_observer` | inference row carrying `observed_by` → CHECK violation |
| `ground_truth_needs_observer` | ground-truth row with no observer → CHECK violation |
| `ground_truth_has_no_confidence` | observation carrying a confidence score → CHECK violation |
| `trg_assertion_no_overwrite` | **inference UPDATE onto asserted ground truth → `ERROR: inference cannot overwrite ground truth`** |
| Ground truth after the attempt | unchanged at `{"lat": 12.97}`; the inference row stayed `candidate` |
| `trg_structure_code_requires_prior_survey` | code on an un-surveyed candidate → refused |
| same, bypass attempt | `SET code=…, status='surveyed'` in one statement → refused |
| same, legitimate path | code on an already-surveyed structure → accepted |
| `structure.code` UNIQUE | duplicate code → refused |
| `non_residential_needs_subtype` | non-residential without subtype → refused; with subtype → accepted |
| `dedup_candidate` distinct pair | structure compared with itself → refused |

**Identity isolation (`scripts/c3-isolation-test.sh`), all verified by execution:**

| Check | Result |
|---|---|
| `registry_api` → `registry_db` | succeeds |
| `registry_api` → `identity_db` | **`FATAL: permission denied for database "identity_db"`** |
| `consent_api` → `identity_db` | succeeds |
| `identity_db` FKs targeting structural tables | none |
| `structure_link.structure_code` | `text`, never a structural row reference |
| `PUBLIC` CONNECT on `identity_db` | revoked |
| `registry_api` grants inside `identity_db` | none |

### Two defects these tests found and fixed

**1. C1 was not actually enforced.** The original design used only a row-state
CHECK (`code IS NULL OR status IN ('surveyed', …)`). A single
`UPDATE structure SET code='SLR-C40001', status='surveyed'` satisfies it — an
automated caller could mint an identity in the same breath that it promoted a
pin. A row-state check cannot express "the code appeared *after* the survey".
Replaced with `trg_structure_code_requires_prior_survey`, which reads `OLD.status`
and refuses the code unless the structure was **already** surveyed before the
statement ran.

**2. C3 isolation had a real hole.** Every role holds `CONNECT` on every database
by default via `PUBLIC`. "registry_api has no explicit grant" is therefore *not*
isolation — it connects anyway. The test failed on its first run, which is the
only reason it was written. Fixed by `REVOKE ALL ON DATABASE identity_db FROM
PUBLIC` plus an explicit grant to `consent_api` only. Both scripts now also
refuse to report a pass when the server is dead, since a dead server makes every
negative assertion pass vacuously — a false-negative failure mode hit twice
while building these.

### Still unverified — requires real PostGIS

`migrations/001_postgis_verify.sql` exists precisely to close this gap by
execution rather than assertion, but **it has not been run**: PostGIS is not
installed and Docker is unavailable on the authoring machine.

- `geometry(Polygon, 4326)` / `geometry(Point, 4326)` typmods
- all `USING gist` spatial indexes
- `ST_Contains` zone containment in `v_zone_service_stats` (C7)
- `tstzrange` supply-hour semantics

The migration suite here shims `geometry` and `tstzrange` as text domains
(`scripts/shims/no-postgis.sql`) and strips gist indexes. **This proves DDL
validity, FK ordering, CHECK constraints and triggers — it proves nothing about
spatial behaviour.** Applying `001_postgis_verify.sql` against a PostGIS
instance is an M1 exit requirement.

---

## 6. Migration Strategy

- Versioned SQL migrations (`migrations/NNN_name.up.sql` / `.down.sql`), applied by a single migrator container at deploy.
- PostGIS extension created in `000_init`; graph tables arrive in the path-graph milestone, not init.
- `identity_db` migrates on a separate schedule and separate credentials — a structural migration never blocks an identity migration.
- Client SQLite schema versioned independently; migration runs inside the app's startup transaction before sync opens.

*End of Database Document*