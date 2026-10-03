-- Shim for environments WITHOUT PostGIS.
--
-- Lets the registry migration be applied on a plain PostgreSQL cluster so that
-- DDL validity, foreign-key ordering, CHECK constraints and the C8 trigger can
-- be verified in CI.
--
-- THIS PROVES NOTHING ABOUT SPATIAL BEHAVIOUR. geometry and tstzrange become
-- opaque text; containment, distance and gist indexes are untested. The
-- spatial layer remains unverified until
-- services/registry-api/migrations/001_postgis_verify.sql runs against real
-- PostGIS.
--
-- A C extension is unnecessary here: the harness only needs the types to
-- exist and accept NULL. PostGIS itself is not being emulated.

CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE DOMAIN geometry   AS text;
CREATE DOMAIN tstzrange  AS text;

-- placeholder; the real implementation is PostGIS's
CREATE FUNCTION ST_Contains(anyelement, anyelement) RETURNS boolean
  AS $$ SELECT false $$ LANGUAGE sql;
