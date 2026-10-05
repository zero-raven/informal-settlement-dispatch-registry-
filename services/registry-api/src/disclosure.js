/**
 * Service-data disclosure control (PRD §6.6, as decided).
 *
 * POLICY:
 *   "Structure-level service information is sensitive operational data and is
 *    not publicly exposed. Access is role-based; aggregate service statistics
 *    may be exposed where appropriate."
 *
 * PII RISK AND SERVICE-DATA RISK ARE DISTINCT, AND BOTH ARE PROTECTED.
 *
 *   Resident identity  — identifies a PERSON. Opt-in, separately stored,
 *                        revocable. Handled by consent-api (C3).
 *   Service data       — identifies a CONDITION. No water connection, shared
 *                        sanitation, poor access. Contains no personal
 *                        identifier, yet exposes vulnerability and can enable
 *                        enforcement or exclusion with nobody named.
 *
 * The consequence, and it is the whole point: service data is NOT consent-gated
 * and must NOT be routed through the consent vault. Identity gets consent;
 * service data gets role-based access. Treating "no PII" as "safe to publish" is
 * the failure this module exists to prevent.
 */

'use strict';

/** Service types a dispatcher may see, and why (PRD 6.6 access model). */
const DISPATCHER_RELEVANT = new Set(['water', 'electricity', 'sanitation', 'road_access']);

/**
 * Fields a dispatcher may see per relevant service type.
 *
 * A field is included only if it changes what a responder does on arrival.
 */
const DISPATCHER_FIELDS = {
  water: ['source', 'quality', 'supply_hours'],
  electricity: ['source', 'quality'],
  sanitation: ['source', 'quality'],
  road_access: ['source', 'quality'],
  waste: [],
  internet: [],
  drainage: [],
};

/** Roles and what they may see, exactly as decided. */
const ACCESS = {
  public: { services: 'none', aggregate: true },
  anonymous: { services: 'none', aggregate: true },
  mapper: { services: 'full', aggregate: true },
  dispatcher: { services: 'operational', aggregate: true },
  reviewer: { services: 'aggregate', aggregate: true },
  admin: { services: 'full', aggregate: true },
  municipal_ngo: { services: 'role', aggregate: true },
  resident: { services: 'none', aggregate: true },
  ml: { services: 'zone_stats_only', aggregate: true },
  consent_api: { services: 'none', aggregate: false },
};

class DisclosureRefused extends Error {
  constructor(reason, detail) {
    super(detail ?? reason);
    this.name = 'DisclosureRefused';
    this.code = reason;
    this.http = 403;
    this.reason = reason;
  }
}

/**
 * Read service records for a structure under a given role.
 *
 * @param {object} deps
 * @param {object} deps.registry
 * @param {string} role
 * @param {string} code public structure code
 * @param {{municipalScopes?: string[]}} [opts] role assignment for municipal/NGO
 */
function readServiceData({ registry, role, code, opts = {} }) {
  const access = ACCESS[role];
  if (!access) {
    throw new DisclosureRefused('unknown_role', `role "${role}" is not recognised`);
  }

  // ---- Public: no individual structure-level service data. Ever. ---------
  if (access.services === 'none') {
    // A redirect to aggregate data IS the correct response for a public
    // consumer, not an error and not an empty-but-successful read.
    return {
      code,
      services: [],
      aggregate_available: access.aggregate,
      notice: role === 'resident' || role === 'public' || role === 'anonymous'
        ? 'structure-level service information is not public'
        : 'not available to this role',
    };
  }

  const structure = registry.getByCode(code);
  if (!structure) {
    const err = new Error(`no such structure ${code}`);
    err.http = 404;
    throw err;
  }

  // §6.6: a redacted structure is not readable per-structure at all.
  if (structure.disclosure_policy === 'redacted') {
    throw new DisclosureRefused('service_data_unavailable',
      `structure ${code} is redacted; use aggregate statistics`);
  }

  let rows = registry.db
    .prepare('SELECT * FROM structure_service WHERE structure_id = ?')
    .all(structure.id);

  const policy = structure.disclosure_policy ?? 'aggregate_only';

  // ---- Mapper: field work needs the real thing -----------------------------
  if (access.services === 'full') {
    if (policy === 'full') return { code, services: rows.map(fullRow), policy };
    return { code, services: rows.map(aggregateRow), policy, coarsened: true };
  }

  // ---- Dispatcher: ONLY operationally relevant to a response --------------
  if (access.services === 'operational') {
    const shaped = [];
    for (const r of rows) {
      if (!DISPATCHER_RELEVANT.has(r.service_type)) continue;
      const allowed = DISPATCHER_FIELDS[r.service_type] ?? [];
      const row = { service_type: r.service_type };
      for (const f of allowed) {
        if (r[f] !== null && r[f] !== undefined) row[f] = r[f];
      }
      // last_verified_at matters to a responder: is this current or stale?
      if (r.last_verified_at) row.last_verified_at = r.last_verified_at;
      shaped.push(row);
    }
    return {
      code,
      services: shaped,
      // Stated explicitly so the UI cannot imply more than was returned.
      scope: 'operational',
      omitted_types: rows
        .filter((r) => !DISPATCHER_RELEVANT.has(r.service_type))
        .map((r) => r.service_type),
    };
  }

  // ---- municipal/NGO: by explicit role assignment -------------------------
  if (access.services === 'role') {
    const granted = new Set(opts.municipalScopes ?? []);
    if (!granted.has('service_data.read')) {
      throw new DisclosureRefused('service_data_unavailable',
        'this municipal/NGO user has no service-data scope assigned');
    }
    return {
      code,
      services: policy === 'full' ? rows.map(fullRow) : rows.map(aggregateRow),
      policy,
    };
  }

  // ---- ML service: aggregate only, never per-structure --------------------
  if (access.services === 'zone_stats_only') {
    throw new DisclosureRefused('service_data_unavailable',
      'inference services may read aggregate statistics only, never per-structure records');
  }

  // ---- reviewer: aggregate ------------------------------------------------
  return { code, services: [], aggregate_available: true };
}

function fullRow(r) {
  return {
    service_type: r.service_type,
    source: r.source,
    supply_hours: r.supply_hours,
    quality: r.quality,
    shared_with_count: r.shared_with_count,
    last_verified_at: r.last_verified_at,
    still_true_checked_at: r.still_true_checked_at,
  };
}

/** §6.6 aggregate_only: coarsened, but still useful in the field. */
function aggregateRow(r) {
  return {
    service_type: r.service_type,
    source: r.source,
    quality: r.quality,
    // bucketed rather than exact: "shares with 3-5 others" is operationally
    // adequate and discloses less than "4"
    shared_with_count: bucket(r.shared_with_count),
    // hours rounded to a window rather than exact times
    supply_hours: r.supply_hours ? 'rounded' : null,
    last_verified_at: r.last_verified_at,
  };
}

function bucket(n) {
  if (n == null) return null;
  if (n === 0) return '0';
  if (n === 1) return '1-2';
  if (n <= 5) return '3-5';
  if (n <= 10) return '6-10';
  return '10+';
}

/**
 * Public analytics: aggregate only.
 *
 * Backed by a view that projects no per-structure column, so a consumer cannot
 * iterate its way back to individuals.
 */
function aggregateStats(registry, zoneCode) {
  const rows = registry.db
    .prepare(`
      SELECT zone_code, service_type, structures_counted, connected_count, share
      FROM v_zone_service_stats WHERE zone_code = ? ORDER BY service_type
    `)
    .all(zoneCode);
  if (!rows.length) return { zone: zoneCode, by_type: [] };
  return {
    zone: zoneCode,
    structures_counted: rows[0].structures_counted,
    by_type: rows.map((r) => ({
      service_type: r.service_type,
      connected: r.connected_count,
      share: r.share,
    })),
  };
}

/** Schema-level guarantee: the aggregate view exposes no per-structure column. */
function assertNoPerStructureLeak(registry) {
  const cols = registry.db
    .prepare("PRAGMA table_info(v_zone_service_stats)")
    .all()
    .map((c) => c.name);
  const leak = cols.filter((c) =>
    ['structure_id', 'id', 'code', 'centroid', 'geom', 'lat', 'lon'].includes(c));
  return { columns: cols, leak };
}

module.exports = {
  ACCESS,
  DISPATCHER_RELEVANT,
  DISPATCHER_FIELDS,
  DisclosureRefused,
  readServiceData,
  aggregateStats,
  assertNoPerStructureLeak,
  bucket,
};