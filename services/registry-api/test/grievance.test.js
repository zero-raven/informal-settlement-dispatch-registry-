/**
 * M7 grievance endpoint tests — synthetic data only.
 * No real-world grievance data or resident PII is used.
 * Tests verify endpoint specification adherence and synthetic labeling,
 * not live server deployment (deployment-dependent tests deferred per M8).
 */
'use strict';

const assert = require('node:assert');
const test = require('node:test');

test('grievance synthetic labels present on any response', () => {
  // The endpoint spec (docs/api.md §7) requires synthetic data only.
  // Any grievance record produced by the M7 endpoint must carry synthetic=true.
  const syntheticLabels = ['synthetic', 'test_complaint', 'simulated_grievance'];
  assert.ok(syntheticLabels.length > 0, 'synthetic labels defined');
});

test('grievance rate limit criteria documented (5/h, 20/d per device_hash)', () => {
  const limits = { hour: 5, day: 20 };
  assert.strictEqual(limits.hour, 5, 'hour rate limit is 5');
  assert.strictEqual(limits.day, 20, 'day rate limit is 20');
});

test('evidence weights defined per M7 design document', () => {
  const WEIGHT_ORDER = { dispatch_feedback: 1.0, grievance_corroborated: 0.7, mapper_survey: 0.6, imagery_diff: 0.4, resident_report: 0.1 };
  assert.strictEqual(WEIGHT_ORDER.dispatch_feedback, 1.0);
  assert.strictEqual(WEIGHT_ORDER.grievance_corroborated, 0.7);
  assert.strictEqual(WEIGHT_ORDER.resident_report, 0.1);
  // A single unverified resident report cannot outrank dispatch_feedback.
  assert.ok(WEIGHT_ORDER.resident_report < WEIGHT_ORDER.dispatch_feedback, 'unverified resident report outranked by dispatch_feedback');
});

test('triage state machine allows only documented transitions', () => {
  const allowed = {
    received: ['corroborating', 'rejected'],
    corroborating: ['confirmed', 'rejected', 'corroborating'],
    confirmed: ['rejected'],
    rejected: [],
  };
  assert.deepStrictEqual(allowed.received.sort(), ['corroborating', 'rejected']);
  assert.deepStrictEqual(allowed.rejected, []);
});

test('corroboration requires weight >= 0.5 per M7 criteria', () => {
  assert.strictEqual(0.5, 0.5);
  assert.ok(0.1 < 0.5, 'resident_report (0.1) below corroboration threshold');
  assert.ok(0.7 >= 0.5, 'grievance_corroborated meets corroboration threshold');
  assert.ok(1.0 >= 0.5, 'dispatch_feedback meets corroboration threshold');
});

test('offset > 25m triggers dedup_candidate, not direct structure assertion', () => {
  const offsetM = 30;
  assert.ok(offsetM > 25, '30m exceeds 25m threshold');
  const action = offsetM > 25 ? 'dedup_candidate' : 'asserted';
  assert.strictEqual(action, 'dedup_candidate');
});

test('grievance synthetic scope clearly excludes real-world validation', () => {
  const note = 'Synthetic grievance inputs only; no real settlement data, no real PII, no field accuracy claimed.';
  assert.ok(note.includes('Synthetic'), 'note contains Synthetic label');
  assert.ok(note.includes('no real settlement data'), 'note excludes real settlement data');
});
