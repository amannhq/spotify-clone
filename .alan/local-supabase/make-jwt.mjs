// Mints the HS256 JSON Web Tokens the local stack uses for the anon and
// service_role API keys. Usage:
//   node make-jwt.mjs <secret> <role> [expiry-in-seconds]

import crypto from 'node:crypto';

const [secret, role, expiry = '63072000'] = process.argv.slice(2);

if (!secret || !role) {
    console.error('usage: make-jwt.mjs <secret> <role> [expiry-in-seconds]');
    process.exit(1);
}

const base64url = (input) => Buffer.from(input).toString('base64url');

const issuedAt = Math.floor(Date.now() / 1000);
const header = base64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
const payload = base64url(
    JSON.stringify({
        iss: 'supabase',
        ref: 'local-supabase',
        role,
        iat: issuedAt,
        exp: issuedAt + Number(expiry),
        aud: 'authenticated',
        email: '',
        session_id: crypto.randomUUID(),
    })
);

const signature = crypto
    .createHmac('sha256', secret)
    .update(`${header}.${payload}`)
    .digest('base64url');

process.stdout.write(`${header}.${payload}.${signature}`);
