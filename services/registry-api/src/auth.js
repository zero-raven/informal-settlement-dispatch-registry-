/**
 * Authentication — real tokens, verified server-side.
 *
 * Login exchanges a username + password for a signed bearer token. The
 * token carries the role; privileged endpoints trust ONLY the token.
 * A self-asserted X-Role header is honoured solely when a caller
 * explicitly opts in with `allowRoleHeader: true` (the unit-test harness).
 * Production servers must not set it.
 *
 * Passwords are scrypt-hashed at boot. Demo users ship with documented
 * default passwords for the semester pilot; override via
 * AUTH_USERS_JSON='[{"username":"...","password":"...","role":"..."}]'.
 * The signing secret comes from AUTH_SECRET; the dev default is flagged
 * loudly rather than silently shipped.
 */

'use strict';

const crypto = require('node:crypto');

const DEFAULT_USERS = [
  { username: 'caller', password: 'caller123', role: 'caller' },
  { username: 'dispatcher', password: 'dispatch123', role: 'dispatcher' },
  { username: 'mapper', password: 'mapper123', role: 'mapper' },
  { username: 'reviewer', password: 'review123', role: 'reviewer' },
  { username: 'admin', password: 'admin123', role: 'admin' },
];

const DEV_SECRET = 'dev-only-change-me-in-production';

function getSecret() {
  const secret = process.env.AUTH_SECRET;
  if (secret) return secret;
  if (process.env.NODE_ENV === 'production') {
    throw new Error('AUTH_SECRET must be set in production');
  }
  return DEV_SECRET;
}

function hashPassword(password, salt) {
  return crypto.scryptSync(password, salt, 32).toString('hex');
}

class AuthService {
  constructor({ users = null, secret = null } = {}) {
    this.secret = secret || getSecret();
    this.allowRoleHeader = this.secret === DEV_SECRET && process.env.ALLOW_ROLE_HEADER !== '0';
    const list = users || this._usersFromEnv() || DEFAULT_USERS;
    this.users = new Map();
    for (const u of list) {
      const salt = crypto.randomBytes(16).toString('hex');
      this.users.set(u.username, {
        username: u.username, role: u.role,
        salt, hash: hashPassword(u.password, salt),
      });
    }
  }

  _usersFromEnv() {
    if (!process.env.AUTH_USERS_JSON) return null;
    try { return JSON.parse(process.env.AUTH_USERS_JSON); } catch { return null; }
  }

  login(username, password) {
    const user = this.users.get(username);
    if (!user || typeof password !== 'string') return null;
    const candidate = crypto.scryptSync(password, user.salt, 32);
    const stored = Buffer.from(user.hash, 'hex');
    if (!crypto.timingSafeEqual(candidate, stored)) return null;
    return this.issueToken(user);
  }

  issueToken(user, expiresInSec = 30 * 24 * 3600) {
    const header = Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64url');
    const payload = Buffer.from(JSON.stringify({
      sub: user.username, role: user.role,
      iat: Math.floor(Date.now() / 1000),
      exp: Math.floor(Date.now() / 1000) + expiresInSec,
    })).toString('base64url');
    const sig = crypto.createHmac('sha256', this.secret)
      .update(`${header}.${payload}`).digest('base64url');
    return `${header}.${payload}.${sig}`;
  }

  /** Returns {username, role} or null. Rejects tampered/expired tokens. */
  verify(token) {
    if (!token || typeof token !== 'string') return null;
    const parts = token.split('.');
    if (parts.length !== 3) return null;
    const [header, payload, sig] = parts;
    const expected = crypto.createHmac('sha256', this.secret)
      .update(`${header}.${payload}`).digest('base64url');
    const a = Buffer.from(sig); const b = Buffer.from(expected);
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
    let claims;
    try { claims = JSON.parse(Buffer.from(payload, 'base64url').toString()); }
    catch { return null; }
    if (!claims.sub || !claims.role) return null;
    if (claims.exp && claims.exp * 1000 < Date.now()) return null;
    return { username: claims.sub, role: claims.role };
  }
}

module.exports = { AuthService, DEFAULT_USERS, DEV_SECRET };
