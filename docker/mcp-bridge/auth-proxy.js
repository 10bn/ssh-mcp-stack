'use strict';

const http = require('http');
const crypto = require('crypto');
const httpProxy = require('http-proxy');

const PORT = process.env.PORT || 8000;
const INTERNAL_PORT = process.env.INTERNAL_PORT || 8001;
const TARGET = `http://127.0.0.1:${INTERNAL_PORT}`;
const TOKEN = process.env.MCP_BEARER_TOKEN;
const HEALTH_PATH = process.env.HEALTH_PATH || '/healthz';

if (!TOKEN) {
  console.error('[auth-proxy] MCP_BEARER_TOKEN is not set. Refusing to start.');
  process.exit(1);
}

const tokenBuffer = Buffer.from(TOKEN);

function isAuthorized(req) {
  const header = req.headers['authorization'] || '';
  const match = /^Bearer (.+)$/.exec(header);
  if (!match) return false;

  const suppliedBuffer = Buffer.from(match[1]);
  if (suppliedBuffer.length !== tokenBuffer.length) return false;
  return crypto.timingSafeEqual(suppliedBuffer, tokenBuffer);
}

const proxy = httpProxy.createProxyServer({ target: TARGET, ws: true });

proxy.on('error', (err, req, res) => {
  console.error('[auth-proxy] proxy error:', err.message);
  if (res && !res.headersSent && typeof res.writeHead === 'function') {
    res.writeHead(502, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'bad_gateway', message: err.message }));
  }
});

const server = http.createServer((req, res) => {
  if (req.url === HEALTH_PATH) {
    proxy.web(req, res, {});
    return;
  }

  if (!isAuthorized(req)) {
    res.writeHead(401, { 'Content-Type': 'application/json', 'WWW-Authenticate': 'Bearer' });
    res.end(JSON.stringify({ error: 'unauthorized', message: 'Missing or invalid bearer token' }));
    return;
  }

  proxy.web(req, res, {});
});

server.on('upgrade', (req, socket, head) => {
  if (!isAuthorized(req)) {
    socket.destroy();
    return;
  }
  proxy.ws(req, socket, head);
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[auth-proxy] listening on 0.0.0.0:${PORT}, forwarding authorized requests to ${TARGET}`);
});
