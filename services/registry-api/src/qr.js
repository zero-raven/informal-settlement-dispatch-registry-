/**
 * QR rendering for structure placards.
 *
 * PRD 6.1 keeps the public code format PROVISIONAL. The QR therefore encodes
 * the code as an opaque payload and nothing about its internal structure:
 * changing the code format re-renders placards, it does not migrate identity.
 *
 * PRD 6.5: the placard is a required physical dependency, but the grievance flow
 * it points to is entirely in-app. A scan never needs the resident to have an
 * account.
 */

'use strict';

const QRCode = require('qrcode');

/**
 * The encoded payload. Deliberately minimal and versioned: a reader can tell
 * what it is without knowing the code format.
 */
function encodePayload(code, { baseUrl = '' } = {}) {
  const payload = baseUrl
    ? `${baseUrl.replace(/\/$/, '')}/s/${encodeURIComponent(code)}`
    : `SLR:${code}`;
  return { version: 1, payload, code };
}

/**
 * Render the placard QR as SVG.
 * @returns {{payload:string, code:string, svg:string, svg_sha256:string}}
 */
async function renderQr(code, { size = 320, margin = 2, baseUrl = '' } = {}) {
  const { payload, code: c } = encodePayload(code, { baseUrl });
  const svg = await QRCode.toString(payload, {
    type: 'svg',
    errorCorrectionLevel: 'M',
    margin,
    width: size,
    color: { dark: '#000000', light: '#FFFFFF' },
  });
  const svg_sha256 = require('node:crypto')
    .createHash('sha256').update(svg).digest('hex');
  return { payload, code: c, svg, svg_sha256 };
}

/**
 * Resolve a scanned payload back to a code.
 *
 * Accepts both the bare `SLR:<code>` form and the URL form, so a placard
 * printed before the code format changed still resolves.
 */
function decodePayload(payload) {
  if (!payload) return null;
  const s = String(payload).trim();
  // URL form: take everything after the final /s/
  const url = s.match(/\/s\/(.+)$/);
  if (url) return url[1];
  // bare form
  const bare = s.match(/^SLR:(.+)$/);
  if (bare) return bare[1];
  return null;
}

module.exports = { renderQr, encodePayload, decodePayload };