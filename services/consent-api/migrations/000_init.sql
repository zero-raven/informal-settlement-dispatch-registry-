-- 000_init.sql — identity_db
--
-- SEPARATE DATABASE, SEPARATE CREDENTIALS, NO CROSS-DB FOREIGN KEYS (C3).
-- registry-api has no credential capable of reaching this database. The only
-- bridge is the consent service's audited occupant-context resolver, which
-- returns an absence rather than an error when no consent exists.
--
-- This file must never be applied by the registry-api migrator.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE resident (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  display_alias     text,
  enc_name          bytea,
  enc_phone         bytea,
  enc_alt_contact   bytea,
  created_at        timestamptz NOT NULL DEFAULT now(),
  -- right-to-be-forgotten sets this rather than deleting silently
  erased_at         timestamptz
);

-- Consent is opt-in, scoped, and revocable (PRD 6.3).
CREATE TABLE consent (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  resident_id    uuid NOT NULL REFERENCES resident(id) ON DELETE CASCADE,
  scope          text NOT NULL CHECK (scope IN
                   ('store_identity','link_to_structure','share_on_dispatch','receive_notification')),
  granted        boolean NOT NULL,
  granted_at     timestamptz,
  revoked_at     timestamptz,
  policy_version text NOT NULL
);

-- Only rows backed by an active 'link_to_structure' consent are honoured.
CREATE INDEX consent_active_idx ON consent (resident_id, scope)
  WHERE granted AND revoked_at IS NULL;

-- Linkage is by PUBLIC CODE TEXT, resolved at read time through the audited
-- broker. Deliberately NO foreign key to registry_db.structure: if a code is
-- ever reassigned by a dedup merge, the link breaks safely rather than
-- silently repointing a resident at a different building.
CREATE TABLE structure_link (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  resident_id   uuid NOT NULL REFERENCES resident(id) ON DELETE CASCADE,
  structure_code text NOT NULL,
  consent_id    uuid NOT NULL REFERENCES consent(id),
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX structure_link_code_idx ON structure_link (structure_code);

-- One active link per (resident, code).
CREATE UNIQUE INDEX structure_link_active_idx ON structure_link (resident_id, structure_code)
  WHERE consent_id IS NOT NULL;

-- Audit of every occupant-context disclosure. Dispatch accountability is the
-- check on consent-by-design.
CREATE TABLE consent_disclosure_audit (
  id            bigserial PRIMARY KEY,
  structure_code text NOT NULL,
  actor         text NOT NULL,
  scopes        text[] NOT NULL,
  had_context   boolean NOT NULL,
  at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX consent_disclosure_code_idx ON consent_disclosure_audit (structure_code, at DESC);