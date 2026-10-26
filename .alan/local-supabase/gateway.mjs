// Local Supabase-compatible gateway for the spotify-clone development environment.
//
// One port (54321) serves the three surfaces the app talks to:
//   /rest/v1/*    -> PostgREST        (127.0.0.1:54330)
//   /auth/v1/*    -> GoTrue           (127.0.0.1:9999)
//   /storage/v1/* -> local file store (this process)
//
// The storage surface is intentionally small: public object reads and
// multipart uploads, which is all the app uses.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const PORT = Number(process.env.SUPABASE_GATEWAY_PORT || 54321);
const REST_TARGET = { host: '127.0.0.1', port: 54330 };
const AUTH_TARGET = { host: '127.0.0.1', port: 9999 };
const STORAGE_ROOT = process.env.STORAGE_ROOT || path.join(process.cwd(), 'storage');

// The browser reaches the gateway from the app's origin, so the CORS headers
// are answered here. The origin is echoed (not wildcarded) because the auth
// service also sends Access-Control-Allow-Credentials.
const corsHeaders = (req) => ({
    'Access-Control-Allow-Origin': req.headers.origin || '*',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
    'Access-Control-Allow-Headers':
        'authorization, x-client-info, apikey, content-type, prefer, range, x-upsert, accept-profile, content-profile',
    'Access-Control-Expose-Headers': 'content-range, range-unit',
    Vary: 'Origin',
});

const MIME_BY_EXTENSION = {
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.webp': 'image/webp',
    '.svg': 'image/svg+xml',
    '.mp3': 'audio/mpeg',
    '.wav': 'audio/wav',
    '.ogg': 'audio/ogg',
    '.m4a': 'audio/mp4',
};

function sendJson(res, status, body, cors = {}) {
    const payload = JSON.stringify(body);
    res.writeHead(status, {
        'Content-Type': 'application/json; charset=utf-8',
        'Content-Length': Buffer.byteLength(payload),
        ...cors,
    });
    res.end(payload);
}

function readBody(req) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        req.on('data', (chunk) => chunks.push(chunk));
        req.on('end', () => resolve(Buffer.concat(chunks)));
        req.on('error', reject);
    });
}

function proxy(target, targetPath, req, res) {
    const headers = { ...req.headers };
    delete headers.host;
    headers.host = `${target.host}:${target.port}`;

    const upstream = http.request(
        {
            host: target.host,
            port: target.port,
            method: req.method,
            path: targetPath,
            headers,
        },
        (upstreamRes) => {
            const chunks = [];
            upstreamRes.on('data', (chunk) => chunks.push(chunk));
            upstreamRes.on('end', () => {
                const body = Buffer.concat(chunks);
                const outHeaders = {};
                for (const [name, value] of Object.entries(upstreamRes.headers)) {
                    // Upstream CORS headers are replaced by this gateway's own;
                    // a second copy would be an invalid duplicate header.
                    if (name.startsWith('access-control-') || name === 'vary') continue;
                    if (name === 'transfer-encoding' || name === 'content-length') continue;
                    outHeaders[name] = value;
                }
                outHeaders['Content-Length'] = body.length;
                // The browser talks to this gateway from the app's origin, so
                // the CORS headers are set here rather than left to the
                // upstream service.
                Object.assign(outHeaders, corsHeaders(req));
                res.writeHead(upstreamRes.statusCode || 502, outHeaders);
                res.end(body);
            });
        }
    );

    upstream.on('error', (error) => {
        sendJson(res, 502, { message: `upstream error: ${error.message}` }, corsHeaders(req));
    });
    req.pipe(upstream);
}

// Minimal multipart/form-data parser: returns the first file part.
function parseMultipart(buffer, boundary) {
    const delimiter = Buffer.from(`--${boundary}`);
    const parts = [];
    let index = buffer.indexOf(delimiter);
    while (index !== -1) {
        const start = index + delimiter.length;
        const next = buffer.indexOf(delimiter, start);
        if (next === -1) break;
        parts.push(buffer.slice(start, next));
        index = next;
    }
    for (const part of parts) {
        const headerEnd = part.indexOf('\r\n\r\n');
        if (headerEnd === -1) continue;
        const headerText = part.slice(0, headerEnd).toString('utf8');
        if (!/filename=/i.test(headerText)) continue;
        let content = part.slice(headerEnd + 4);
        if (content.subarray(content.length - 2).toString() === '\r\n') {
            content = content.subarray(0, content.length - 2);
        }
        const filenameMatch = headerText.match(/filename="([^"]*)"/i);
        const typeMatch = headerText.match(/content-type:\s*([^\r\n]+)/i);
        return {
            filename: filenameMatch ? filenameMatch[1] : 'upload',
            contentType: typeMatch ? typeMatch[1].trim() : 'application/octet-stream',
            data: content,
        };
    }
    return null;
}

function objectPath(bucket, objectName) {
    const safe = path
        .normalize(objectName)
        .replace(/^(\.\.(\/|\\|$))+/, '')
        .replace(/^\/+/, '');
    return path.join(STORAGE_ROOT, bucket, safe);
}

async function handleStorage(req, res, url) {
    const json = (status, body) => sendJson(res, status, body, corsHeaders(req));

    // /storage/v1/object/public/<bucket>/<path...>
    const publicMatch = url.pathname.match(/^\/storage\/v1\/object\/public\/([^/]+)\/(.+)$/);
    if (publicMatch) {
        const file = objectPath(publicMatch[1], publicMatch[2]);
        if (!fs.existsSync(file) || !fs.statSync(file).isFile()) {
            return json(404, { error: 'not_found', message: 'Object not found' });
        }
        const body = fs.readFileSync(file);
        res.writeHead(200, {
            'Content-Type': MIME_BY_EXTENSION[path.extname(file).toLowerCase()] || 'application/octet-stream',
            'Content-Length': body.length,
            'Cache-Control': 'public, max-age=3600',
            ...corsHeaders(req),
        });
        return res.end(body);
    }

    // /storage/v1/object/<bucket>/<path...>  (upload)
    const uploadMatch = url.pathname.match(/^\/storage\/v1\/object\/([^/]+)\/(.+)$/);
    if (uploadMatch && (req.method === 'POST' || req.method === 'PUT')) {
        const bucket = uploadMatch[1];
        const objectName = uploadMatch[2];
        const contentType = req.headers['content-type'] || '';
        const boundaryMatch = contentType.match(/boundary=(?:"([^"]+)"|([^;]+))/i);
        const body = await readBody(req);
        let data = body;
        let fileName = objectName;
        let detectedType = contentType;
        if (boundaryMatch) {
            const file = parseMultipart(body, (boundaryMatch[1] || boundaryMatch[2]).trim());
            if (!file) {
                return json(400, { error: 'InvalidRequest', message: 'file part missing' });
            }
            data = file.data;
            fileName = file.filename || objectName;
            detectedType = file.contentType;
        }
        const target = objectPath(bucket, objectName);
        fs.mkdirSync(path.dirname(target), { recursive: true });
        fs.writeFileSync(target, data);
        return json(200, {
            Id: `${bucket}/${objectName}`,
            Key: objectName,
            Path: objectName,
            name: fileName,
            bucketId: bucket,
            size: data.length,
            type: detectedType,
            metadata: {},
        });
    }

    // /storage/v1/object/list/<bucket>
    const listMatch = url.pathname.match(/^\/storage\/v1\/object\/list\/([^/]+)$/);
    if (listMatch) {
        const bucket = listMatch[1];
        const dir = path.join(STORAGE_ROOT, bucket);
        const objects = fs.existsSync(dir)
            ? fs.readdirSync(dir, { recursive: true }).map((entry) => ({
                  name: path.basename(String(entry)),
                  id: `${bucket}/${String(entry)}`,
                  bucket_id: bucket,
                  updated_at: new Date().toISOString(),
                  metadata: { mimetype: 'application/octet-stream' },
              }))
            : [];
        return json(200, objects);
    }

    return json(404, { error: 'not_found', message: 'unknown storage route' });
}

const server = http.createServer(async (req, res) => {
    const url = new URL(req.url || '/', `http://${req.headers.host || '127.0.0.1'}`);

    try {
        if (req.method === 'OPTIONS') {
            res.writeHead(204, corsHeaders(req));
            return res.end();
        }

        if (url.pathname === '/') {
            return sendJson(res, 200, {
                service: 'local-supabase-gateway',
                rest: '/rest/v1',
                auth: '/auth/v1',
                storage: '/storage/v1',
            }, corsHeaders(req));
        }

        if (url.pathname.startsWith('/rest/v1')) {
            // PostgREST serves its API from the root; strip the /rest/v1 prefix.
            const stripped = url.pathname.replace(/^\/rest\/v1/, '') || '/';
            return proxy(REST_TARGET, `${stripped}${url.search}`, req, res);
        }

        if (url.pathname.startsWith('/auth/v1')) {
            const stripped = url.pathname.replace(/^\/auth\/v1/, '') || '/';
            return proxy(AUTH_TARGET, `${stripped}${url.search}`, req, res);
        }

        if (url.pathname.startsWith('/storage/v1')) {
            if (req.method === 'OPTIONS') {
                res.writeHead(204, corsHeaders(req));
                return res.end();
            }
            return await handleStorage(req, res, url);
        }

        res.writeHead(404, { 'Content-Type': 'application/json', ...corsHeaders(req) });
        return res.end(JSON.stringify({ message: 'not found' }));
    } catch (error) {
        return sendJson(res, 500, { message: error.message }, corsHeaders(req));
    }
});

fs.mkdirSync(STORAGE_ROOT, { recursive: true });
server.listen(PORT, '127.0.0.1', () => {
    console.log(`supabase gateway listening on http://127.0.0.1:${PORT}`);
});
