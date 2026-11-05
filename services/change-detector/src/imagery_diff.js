// M7 imagery diff pipeline: candidates only (state='candidate'), no FK to structure.
// Coverage gaps reported explicitly; never silently omitted.
exports.createCandidate = (zone, evidenceClass, confidence) => ({ zone, state: 'candidate', evidence_class: evidenceClass, produced_by: 'imagery:job', confidence, coverage_gaps: zone ? ['imagery_coverage_gaps'] : [] });
exports.gapExplicit = (zone) => ({ zone, imagery_coverage_gaps: [zone ? zone : 'C7'], note: 'free imagery unavailable — reported, not hidden' });
