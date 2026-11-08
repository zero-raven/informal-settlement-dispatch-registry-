// Authentication: login issues tokens, tokens verify, tampering fails,
// privileged endpoints refuse unauthenticated callers.
'use strict';

const assert = require('node:assert');
const test = require('node:test');
const { AuthService } = require('../src/auth.js');
const { createServer } = require('../src/server.js');

test('login with correct password issues a token carrying the role', () => {
  const auth = new AuthService({ users: [{ username: 'u1', password: 'pw', role: 'dispatcher' }], secret: 'test-secret' });
  const token = auth.login('u1', 'pw');
  assert.ok(token);
  assert.deepStrictEqual(auth.verify(token), { username: 'u1', role: 'dispatcher' });
});

test('login with wrong password fails', () => {
  const auth = new AuthService({ users: [{ username: 'u1', password: 'pw', role: 'dispatcher' }], secret: 'test-secret' });
  assert.strictEqual(auth.login('u1', 'wrong'), null);
  assert.strictEqual(auth.login('nobody', 'pw'), null);
});

test('a tampered token is rejected', () => {
  const auth = new AuthService({ users: [{ username: 'u1', password: 'pw', role: 'dispatcher' }], secret: 'test-secret' });
  const token = auth.login('u1', 'pw');
  const [h, p, s] = token.split('.');
  const forgedPayload = Buffer.from(JSON.stringify({ sub: 'u1', role: 'admin', exp: 9999999999 })).toString('base64url');
  assert.strictEqual(auth.verify(`${h}.${forgedPayload}.${s}`), null);
});

test('an expired token is rejected', () => {
  const auth = new AuthService({ users: [{ username: 'u1', password: 'pw', role: 'dispatcher' }], secret: 'test-secret' });
  const token = auth.issueToken({ username: 'u1', role: 'dispatcher' }, -10);
  assert.strictEqual(auth.verify(token), null);
});

test('privileged endpoints require a token when role headers are not opted in', async () => {
  const auth = new AuthService({ users: [{ username: 'd1', password: 'pw', role: 'dispatcher' }], secret: 'test-secret' });
  const server = createServer({ auth, allowRoleHeader: false });
  await new Promise((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    // No token, but a spoofed X-Role header: must be refused.
    const spoofed = await fetch(`${base}/v1/dispatch/stats`, { headers: { 'X-Role': 'admin' } });
    assert.strictEqual(spoofed.status, 401);

    // Bad credentials.
    const bad = await fetch(`${base}/v1/auth/login`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'd1', password: 'nope' }),
    });
    assert.strictEqual(bad.status, 401);

    // Real login, then authorised access.
    const login = await fetch(`${base}/v1/auth/login`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'd1', password: 'pw' }),
    });
    assert.strictEqual(login.status, 200);
    const { token, role } = await login.json();
    assert.strictEqual(role, 'dispatcher');
    const stats = await fetch(`${base}/v1/dispatch/stats`, { headers: { Authorization: `Bearer ${token}` } });
    assert.strictEqual(stats.status, 200);
  } finally { server.close(); }
});
