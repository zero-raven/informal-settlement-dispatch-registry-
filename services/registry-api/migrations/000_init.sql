-- 000_init.sql — registry_db
-- Structural registry. NO resident PII (constraint C3, PRD 4).
-- Spatial types require PostGIS; this migration is the first thing that
-- needs it, and it is the blocker recorded in docs/database.md 5.

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------------
-- Enumerations
-- ---------------------------------------------------------------------------

-- PRD 6.1 RESOLVED. A structure is a physically distinguishable residential
-- unit that can be assigned a unique destination for mapping and dispatch.
CREATE TYPE structure_type AS ENUM (
  'standalone_dwelling',
  'shared_wall_dwelling',
  'multi_household_single_entry',
  'compound_dwelling',
  'temporary_shelter',
  'non_residential'
);

-- PRD 6.6 RESOLVED. Service data is sensitive operational data, not public.
CREATE TYPE disclosure_policy AS ENUM (
  'full',
  'aggregate_only',
  'redacted'
);

CREATE TYPE structure_status AS ENUM (
  'candidate', 'surveyed', 'verified', 'disputed', 'demolished', 'unreachable'
);

CREATE TYPE verification_method AS ENUM (
  'footprint_bootstrap', 'mapper_survey', 'resident_report',
  'dispatch_feedback', 'imagery_diff', 'dedup_review', 'grievance_corroborated'
);

CREATE TYPE service_type AS ENUM (
  'water', 'electricity', 'sanitation', 'waste', 'internet',
  'road_access', 'drainage'
);

CREATE TYPE service_source AS ENUM (
  'utility', 'informal_tap', 'shared_private', 'community', 'none', 'unknown'
);

CREATE TYPE quality_rating AS ENUM ('good', 'fair', 'poor', 'unknown');

CREATE TYPE grievance_state AS ENUM (
  'received', 'triaged', 'corroborating', 'resolved', 'rejected'
);

CREATE TYPE sync_op AS ENUM ('create', 'update', 'delete');

-- C8. Every asserted value carries its evidence class.
CREATE TYPE evidence_class AS ENUM (
  'ground_truth',   -- mapper verification, responder observation, resident report
  'inference'       -- trace clustering, imagery diff, route confidence, dedup candidates
);

-- C8. Inference -> candidate -> verification -> ground-truth update.
CREATE TYPE assertion_state AS ENUM ('asserted', 'candidate', 'superseded');

-- ---------------------------------------------------------------------------
-- structure — the core entity. No PII, no location-derived identity.
-- ---------------------------------------------------------------------------

CREATE TABLE structure (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Public short code. NULL until a human dedup decision issues it.
  -- Never written by AI (C1); never derived from position (PRD 6.1).
  code                     text UNIQUE,
  status                   structure_status NOT NULL DEFAULT 'candidate',
  structure_type           structure_type NOT NULL DEFAULT 'standalone_dwelling',
  -- PRD 6.1: non-residential must carry an explicit type.
  non_residential_subtype  text,
  footprint                geometry(Polygon, 4326),
  centroid                 geometry(Point, 4326) NOT NULL,
  access_point             geometry(Point, 4326),
  -- PRD 6.1: the definition turns on independent destinations, so the
  -- entrance is first-class geometry, not a note field.
  entrance_geom            geometry(Point, 4326),
  entrance_independent     boolean,
  -- self-reference: compound parent for independently accessible dwellings
  compound_root_id         uuid REFERENCES structure(id),
  floors_estimated         smallint CHECK (floors_estimated >= 0),
  material_primary         text,
  -- Structural aggregate only. Never linked to any identity record.
  occupancy_estimate       smallint CHECK (occupancy_estimate >= 0),
  is_shared_wall           boolean NOT NULL DEFAULT false,
  shares_wall_with         uuid REFERENCES structure(id),
  disclosure_policy        disclosure_policy NOT NULL DEFAULT 'aggregate_only',
  -- PRD 6.1: CANDIDATE-GENERATION threshold only. NOT the definition of a
  -- structure. Passing it means a human reviews; it never means "same building".
  dedup_threshold_m        numeric(6,2) NOT NULL DEFAULT 12.00,
  first_seen_at            timestamptz NOT NULL DEFAULT now(),
  last_verified_at         timestamptz,
  verification_src         verification_method,
  version                  integer NOT NULL DEFAULT 1,
  created_by               uuid NOT NULL,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  deleted_at               timestamptz,
  CONSTRAINT verified_needs_source CHECK (
    status <> 'verified'
    OR (last_verified_at IS NOT NULL AND verification_src IS NOT NULL)
  ),
  CONSTRAINT non_residential_needs_subtype CHECK (
    structure_type <> 'non_residential' OR non_residential_subtype IS NOT NULL
  ),
  -- A code, once issued, must correspond to a structure that is at least
  -- surveyed. Bootstrapped candidates never carry a code.
  CONSTRAINT code_requires_survey CHECK (
    code IS NULL OR status IN ('surveyed','verified','demolished','unreachable')
  ),
  -- A structure under dedup review has no code yet: code issuance is a
  -- consequence of the human decision, never a precondition for entering it.
  CONSTRAINT code_not_while_disputed CHECK (
    code IS NULL OR status <> 'disputed'
  )
);

CREATE INDEX structure_centroid_gix  ON structure USING gist (centroid);
CREATE INDEX structure_entrance_gix  ON structure USING gist (entrance_geom);
CREATE INDEX structure_footprint_gix ON structure USING gist (footprint);
CREATE INDEX structure_status_idx     ON structure (status) WHERE deleted_at IS NULL;
CREATE INDEX structure_lastverif_idx  ON structure (last_verified_at NULLS FIRST);
CREATE INDEX structure_compound_idx   ON structure (compound_root_id)
                                     WHERE compound_root_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- assertion — C8 made mechanical.
-- ---------------------------------------------------------------------------

CREATE TABLE assertion (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_table   text NOT NULL,
  entity_id      uuid NOT NULL,
  field          text NOT NULL,
  value          jsonb NOT NULL,
  evidence_class evidence_class NOT NULL,
  state          assertion_state NOT NULL DEFAULT 'asserted',
  source         verification_method NOT NULL,
  -- ground-truth provenance; NULL for inference by construction
  observed_by    text,
  observed_at    timestamptz,
  -- inference provenance
  produced_by    text,
  produced_at    timestamptz,
  confidence     real,
  supersedes_id  uuid REFERENCES assertion(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ground_truth_needs_observer CHECK (
    evidence_class <> 'ground_truth'
    OR (observed_by IS NOT NULL AND observed_at IS NOT NULL)
  ),
  CONSTRAINT inference_has_no_observer CHECK (
    evidence_class <> 'inference' OR observed_by IS NULL
  ),
  -- C8: an inference row can only ever be a candidate.
  CONSTRAINT inference_only_candidates CHECK (
    evidence_class <> 'inference' OR state = 'candidate'
  ),
  -- confidence belongs to inference, never to an observation
  CONSTRAINT ground_truth_has_no_confidence CHECK (
    evidence_class <> 'ground_truth' OR confidence IS NULL
  )
);

CREATE INDEX assertion_entity_idx ON assertion (entity_table, entity_id, field);
CREATE INDEX assertion_candidates_idx ON assertion (state, produced_at DESC)
  WHERE state = 'candidate';
-- Exactly one asserted value per field per entity.
CREATE UNIQUE INDEX assertion_current_idx ON assertion (entity_table, entity_id, field)
  WHERE state = 'asserted';

-- C8: inference must NEVER overwrite ground truth. Enforced by the database,
-- not by convention. Inference writes a candidate row; only an explicit
-- verification transaction promotes anything.
CREATE OR REPLACE FUNCTION assertion_no_inference_overwrite() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.evidence_class = 'ground_truth'
     AND NEW.state = 'asserted'
     AND NEW.evidence_class = 'inference' THEN
    RAISE EXCEPTION
      'inference cannot overwrite ground truth (assertion %, field %)', OLD.id, NEW.field
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_assertion_no_overwrite
  BEFORE UPDATE ON assertion
  FOR EACH ROW EXECUTE FUNCTION assertion_no_inference_overwrite();

-- ---------------------------------------------------------------------------
-- structure_service — structured records per service (PRD 6.6), not flags.
-- ---------------------------------------------------------------------------

CREATE TABLE structure_service (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  structure_id      uuid NOT NULL REFERENCES structure(id) ON DELETE CASCADE,
  service_type      service_type NOT NULL,
  source            service_source NOT NULL DEFAULT 'unknown',
  supply_hours      tstzrange,
  quality           quality_rating NOT NULL DEFAULT 'unknown',
  shared_with_count smallint NOT NULL DEFAULT 0 CHECK (shared_with_count >= 0),
  last_verified_at  timestamptz,
  verification_src  verification_method,
  -- PRD 6.6: cheap "still true?" re-check marker, separate from full survey
  still_true_checked_at timestamptz,
  field_version     integer NOT NULL DEFAULT 1,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (structure_id, service_type)
);

CREATE INDEX structure_service_reverify_idx
  ON structure_service (last_verified_at NULLS FIRST);

-- ---------------------------------------------------------------------------
-- dedup_candidate — human review queue. No auto-merge path exists (C2).
-- ---------------------------------------------------------------------------

CREATE TABLE dedup_candidate (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  structure_a      uuid NOT NULL REFERENCES structure(id),
  structure_b      uuid NOT NULL REFERENCES structure(id),
  -- PRD 6.1: proximity alone never decides. Multiple independent signals.
  distance_m       numeric(8,2) NOT NULL,
  entrance_dist_m  numeric(8,2),
  iou              numeric(5,4),
  wall_shared      boolean NOT NULL DEFAULT false,
  photo_similarity real,
  mapper_conflict  boolean NOT NULL DEFAULT false,
  -- ranking only; never a decision
  score            numeric(5,4) NOT NULL,
  signals          jsonb NOT NULL DEFAULT '{}'::jsonb,
  state            text NOT NULL DEFAULT 'open'
                     CHECK (state IN ('open','in_review','merged','distinct','deferred')),
  reviewer_id      uuid,
  reviewed_at      timestamptz,
  decision_note    text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  -- a structure cannot be compared with itself
  CONSTRAINT distinct_pair CHECK (structure_a <> structure_b)
);

CREATE INDEX dedup_open_idx ON dedup_candidate (score DESC) WHERE state = 'open';

-- ---------------------------------------------------------------------------
-- verification_event — append-only trail, two-speed model (PRD 6.4).
-- ---------------------------------------------------------------------------

CREATE TABLE verification_event (
  id           bigserial PRIMARY KEY,
  structure_id uuid NOT NULL REFERENCES structure(id) ON DELETE CASCADE,
  trigger_kind text NOT NULL CHECK (trigger_kind IN ('fast','slow','manual','bootstrap')),
  source       verification_method NOT NULL,
  outcome      text CHECK (outcome IN
                 ('confirmed','changed','gone','unreachable','inconclusive')),
  payload      jsonb,
  actor        text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX verification_event_structure_idx
  ON verification_event (structure_id, created_at DESC);
CREATE INDEX verification_event_fast_idx
  ON verification_event (trigger_kind, created_at DESC) WHERE trigger_kind = 'fast';

-- ---------------------------------------------------------------------------
-- structure_code_sequence — opaque, non-derivable, zone-scoped.
-- ---------------------------------------------------------------------------

CREATE TABLE structure_code_sequence (
  bucket     smallint PRIMARY KEY,
  next_value integer NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- grievance — geo+photo tagged, rate limited (PRD 6.5).
-- ---------------------------------------------------------------------------

CREATE TABLE grievance (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  structure_id            uuid REFERENCES structure(id),
  reported_geometry       geometry(Point, 4326) NOT NULL,
  photo_object_key        text,
  body                    text,
  state                   grievance_state NOT NULL DEFAULT 'received',
  -- weighting is server-assigned from source, never client-supplied
  weight                  numeric(5,4) NOT NULL DEFAULT 0.1,
  weight_src              verification_method NOT NULL DEFAULT 'resident_report',
  offset_from_registered_m numeric(8,2),
  -- rotating salted hash; NOT an identity
  reporter_hash           text,
  device_hash             text NOT NULL,
  created_at              timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX grievance_state_idx ON grievance (state, created_at DESC);
CREATE INDEX grievance_geom_gix  ON grievance USING gist (reported_geometry);

-- ---------------------------------------------------------------------------
-- walk network — graph edges are INFERENCE until a mapper walks them (C8).
-- ---------------------------------------------------------------------------

CREATE TABLE walk_node (
  id      bigserial PRIMARY KEY,
  geom    geometry(Point, 4326) NOT NULL,
  kind    text NOT NULL DEFAULT 'junction'
            CHECK (kind IN ('junction','gate','stair','obstruction','structure_entrance')),
  support real
);
CREATE INDEX walk_node_geom_gix ON walk_node USING gist (geom);

CREATE TABLE walk_segment (
  id             bigserial PRIMARY KEY,
  source_node    bigint NOT NULL REFERENCES walk_node(id),
  target_node    bigint NOT NULL REFERENCES walk_node(id),
  geom           geometry(LineString, 4326) NOT NULL,
  length_m       real NOT NULL,
  evidence_class evidence_class NOT NULL DEFAULT 'inference',
  state          assertion_state NOT NULL DEFAULT 'candidate',
  -- NULL until verified. Inference must never assume passable (C8).
  passable       boolean,
  confidence     real,
  -- PRD 6.2 superseded by M0 measurement: map-matching backbone, with Delaunay
  -- used only for restricted gap bridging. See docs/architecture.md 5.8.
  derivation     text NOT NULL DEFAULT 'mapmatch'
                   CHECK (derivation IN ('mapmatch','delaunay_bridge','breadcrumb',
                                         'dbscan','nearest_neighbor','manual','bootstrap')),
  algorithm      text,
  build_version  integer NOT NULL
);
CREATE INDEX walk_segment_geom_gix ON walk_segment USING gist (geom);
CREATE INDEX walk_segment_candidates_idx ON walk_segment (state) WHERE state = 'candidate';

CREATE TABLE breadcrumb (
  id           bigserial PRIMARY KEY,
  mapper_id    uuid NOT NULL,
  structure_id uuid REFERENCES structure(id),
  geom         geometry(LineString, 4326) NOT NULL,
  accuracy_m   real,
  captured_at  timestamptz NOT NULL,
  device_meta  jsonb
);
CREATE INDEX breadcrumb_geom_gix ON breadcrumb USING gist (geom);

-- ---------------------------------------------------------------------------
-- zone — PRD 3. Dispatch is gated on containment (C7).
-- ---------------------------------------------------------------------------

CREATE TABLE zone (
  id               serial PRIMARY KEY,
  code             text UNIQUE NOT NULL,
  name             text NOT NULL,
  boundary         geometry(MultiPolygon, 4326) NOT NULL,
  -- the pilot kill switch
  dispatch_enabled boolean NOT NULL DEFAULT false
);
CREATE INDEX zone_boundary_gix ON zone USING gist (boundary);

-- PRD 6.4 slow signal. Imagery diffing produces CANDIDATES, never updates.
-- No foreign key to structure by design: a score reorders visits, nothing else.
CREATE TABLE zone_priority (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  zone_code      text NOT NULL REFERENCES zone(code),
  score          real NOT NULL,
  evidence_class evidence_class NOT NULL DEFAULT 'inference',
  state          assertion_state NOT NULL DEFAULT 'candidate',
  signal         text NOT NULL CHECK (signal IN
                   ('imagery_diff','complaint_cluster','coverage_gap')),
  structures_flagged integer NOT NULL DEFAULT 0,
  last_imagery_at    date,
  recommended_window_days integer,
  produced_by    text NOT NULL,
  produced_at    timestamptz NOT NULL DEFAULT now(),
  superseded_by  uuid REFERENCES zone_priority(id)
);

-- ---------------------------------------------------------------------------
-- users, sync receipts, audit
-- ---------------------------------------------------------------------------

CREATE TABLE app_user (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email      citext UNIQUE NOT NULL,
  role       text NOT NULL CHECK (role IN
               ('mapper','dispatcher','reviewer','admin','municipal_ngo')),
  active     boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE mapper_profile (
  user_id       uuid PRIMARY KEY REFERENCES app_user(id),
  last_sync_at  timestamptz,
  device_id     text,
  device_pubkey bytea
);

-- Idempotency at the sync boundary (C4/C5).
CREATE TABLE sync_receipt (
  client_op_id   uuid PRIMARY KEY,
  client_seq     bigint NOT NULL,
  mapper_id      uuid NOT NULL,
  entity_table   text NOT NULL,
  entity_id      uuid NOT NULL,
  server_version integer NOT NULL,
  received_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX sync_receipt_mapper_idx ON sync_receipt (mapper_id, client_seq);

CREATE TABLE audit_log (
  id     bigserial PRIMARY KEY,
  actor  text NOT NULL,
  action text NOT NULL,
  target text NOT NULL,
  meta   jsonb,
  at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_log_at_idx ON audit_log (at DESC);
CREATE INDEX audit_log_actor_idx ON audit_log (actor, at DESC);

-- ---------------------------------------------------------------------------
-- Aggregate service statistics (PRD 6.6). Reporting consumers read ONLY this.
-- No structure_id, no code, no geometry is projected, so a consumer cannot
-- iterate this view into per-structure rows.
-- ---------------------------------------------------------------------------

CREATE VIEW v_zone_service_stats AS
SELECT z.code                                   AS zone_code,
       count(DISTINCT s.id)                     AS structures_counted,
       sv.service_type,
       count(*) FILTER (WHERE sv.source NOT IN ('none','unknown')) AS connected_count,
       round(
         count(*) FILTER (WHERE sv.source NOT IN ('none','unknown'))::numeric
         / greatest(count(*), 1), 3)            AS share
FROM zone z
JOIN structure s ON ST_Contains(z.boundary, s.centroid)
LEFT JOIN structure_service sv ON sv.structure_id = s.id
WHERE s.deleted_at IS NULL
GROUP BY z.code, sv.service_type;

-- ---------------------------------------------------------------------------
-- updated_at maintenance
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END $$;

CREATE TRIGGER trg_structure_touch BEFORE UPDATE ON structure
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- C1: a code may only APPEAR on a structure that was already surveyed BEFORE
-- this statement. A row-state CHECK cannot express that -- setting code and
-- status in one UPDATE would satisfy it -- so the transition is enforced here.
-- This is what stops an automated caller from minting an identity in the same
-- breath that it promotes a pin. Code issuance happens only inside the human
-- dedup decision (docs/api.md 4.2).
CREATE OR REPLACE FUNCTION structure_code_requires_prior_survey() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  was_surveyed boolean;
BEGIN
  IF NEW.code IS NOT NULL AND OLD.code IS NULL THEN
    -- OLD carries the pre-update status, which is exactly what we need.
    was_surveyed := OLD.status IN ('surveyed','verified','demolished','unreachable');
    IF NOT was_surveyed THEN
      RAISE EXCEPTION
        'code % cannot be issued to a % structure (id %) — a human dedup decision is required',
        NEW.code, OLD.status, OLD.id
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_structure_code_requires_prior_survey
  BEFORE UPDATE OF code ON structure
  FOR EACH ROW EXECUTE FUNCTION structure_code_requires_prior_survey();
CREATE TRIGGER trg_service_touch BEFORE UPDATE ON structure_service
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ---------------------------------------------------------------------------
-- Seed the pilot zone. Dispatch disabled until explicitly enabled (PRD 3).
-- ---------------------------------------------------------------------------

-- Pilot zones. boundary is NOT NULL because C7 enforces dispatch containment
-- against it, so the seed must provide a real polygon rather than NULL.
INSERT INTO zone (code, name, dispatch_enabled, boundary) VALUES
  ('C4', 'Pilot campus zone C4', false,
   ST_Multi(ST_GeomFromText(
     'POLYGON((-77.600 -12.970, 77.600 -12.970, 77.600 12.990, -77.600 12.990, -77.600 -12.970))',
     4326))),
  ('C9', 'Pilot campus zone C9 (dispatch disabled)', false,
   ST_Multi(ST_GeomFromText(
     'POLYGON((77.610 -12.970, 77.700 -12.970, 77.700 -12.900, 77.610 -12.900, 77.610 -12.970))',
     4326)));