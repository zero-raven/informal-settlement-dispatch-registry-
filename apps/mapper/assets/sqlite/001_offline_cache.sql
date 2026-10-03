-- Mapper offline cache.
--
-- Mirrors a subset of registry_db for the mapped zone, plus the pending_op
-- outbox that survives process death. The mapper must be fully usable with no
-- connectivity (C4); this file is what makes that true.
--
-- Applied at app start, BEFORE the sync layer opens (see bootstrap.dart), so a
-- schema mismatch can never produce a corrupt sync.

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------- structures
CREATE TABLE IF NOT EXISTS local_structure (
  local_id             TEXT PRIMARY KEY,
  server_id            TEXT,
  -- public short code; NULL until a human dedup decision issues it
  code                 TEXT,
  -- PRD 6.1 classification, entered by the mapper as an OBSERVATION
  structure_type       TEXT NOT NULL DEFAULT 'standalone_dwelling',
  non_residential_subtype TEXT,
  is_shared_wall       INTEGER NOT NULL DEFAULT 0,
  lat                  REAL NOT NULL,
  lon                  REAL NOT NULL,
  entrance_lat         REAL,
  entrance_lon         REAL,
  -- the 6.1 discriminator: independently identifiable destination?
  entrance_independent INTEGER,
  footprint_json       TEXT,
  floors_estimated     INTEGER,
  material_primary     TEXT,
  occupancy_estimate   INTEGER,
  status               TEXT NOT NULL DEFAULT 'surveyed',
  disclosure_policy    TEXT NOT NULL DEFAULT 'aggregate_only',
  version              INTEGER NOT NULL DEFAULT 0,
  dirty                INTEGER NOT NULL DEFAULT 0,
  last_pulled_at       INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_local_structure_dirty ON local_structure(dirty);
CREATE INDEX IF NOT EXISTS idx_local_structure_code  ON local_structure(code);

-- -------------------------------------------------------------- service data
-- PRD 6.6: structured records, not a binary flag. Default disclosure is
-- aggregate_only; nothing here is ever publicly readable.
CREATE TABLE IF NOT EXISTS local_service (
  local_id             TEXT PRIMARY KEY,
  structure_local_id   TEXT NOT NULL,
  service_type         TEXT NOT NULL,
  source               TEXT,
  supply_from          TEXT,
  supply_to            TEXT,
  quality              TEXT,
  shared_with_count    INTEGER NOT NULL DEFAULT 0,
  last_verified_at     TEXT,
  still_true_checked_at TEXT,
  dirty                INTEGER NOT NULL DEFAULT 0,
  UNIQUE (structure_local_id, service_type)
);

-- ------------------------------------------------------------------- photos
CREATE TABLE IF NOT EXISTS local_photo (
  local_id           TEXT PRIMARY KEY,
  structure_local_id TEXT,
  path              TEXT NOT NULL,
  -- hashed at capture so a re-upload is detectable and idempotent
  sha256            TEXT NOT NULL,
  uploaded          INTEGER NOT NULL DEFAULT 0
);

-- ------------------------------------------------------------------ outbox
-- The queue that makes offline work safe. Every write lands here first; sync
-- drains it in seq order. client_op_id is the server's idempotency key.
CREATE TABLE IF NOT EXISTS pending_op (
  op_id      TEXT PRIMARY KEY,
  seq        INTEGER NOT NULL,
  table_name TEXT NOT NULL,
  entity_id  TEXT NOT NULL,
  op         TEXT NOT NULL CHECK (op IN ('create','update','delete')),
  payload    TEXT NOT NULL,
  site_id    TEXT NOT NULL,
  attempts   INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_pending_op_seq ON pending_op(seq);

-- ---------------------------------------------------------------- sync meta
CREATE TABLE IF NOT EXISTS sync_state (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
-- keys: 'cursor' (opaque, server-authoritative), 'last_sync_at', 'site_id'

-- A restored outbox is the only thing that makes a mid-push process death safe:
-- on launch we rebuild the in-memory queue from these rows, so nothing that was
-- captured but not yet acknowledged is ever lost.
CREATE TABLE IF NOT EXISTS local_grievance (
  local_id           TEXT PRIMARY KEY,
  structure_local_id TEXT,
  lat                REAL NOT NULL,
  lon                REAL NOT NULL,
  body               TEXT,
  photo_local_id     TEXT,
  device_hash        TEXT NOT NULL,
  uploaded           INTEGER NOT NULL DEFAULT 0,
  created_at         INTEGER NOT NULL
);