// Grievance intake (M7): rate limit 5/h + 20/d per device_hash; weight ordering enforced.
// Cross-check: offset_from_registered_m > 25 => dedup record, not structure assertion.
const WEIGHT_ORDER = { dispatch_feedback: 1.0, grievance_corroborated: 0.7, mapper_survey: 0.6, imagery_diff: 0.4, resident_report: 0.1 };
const RATE_LIMIT = { hour: 5, day: 20 };
exports.WEIGHT_ORDER = WEIGHT_ORDER; exports.RATE_LIMIT = RATE_LIMIT;
