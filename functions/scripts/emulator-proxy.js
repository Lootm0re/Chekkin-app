// Serves the emulator web build and passes its Firebase requests on to the
// emulators, all on one port (5050), so the app can reach everything at its
// own origin. That way only one port needs forwarding, and it works over the
// HTTPS that Codespaces forwarded ports use. Started by scripts/emulators.sh.
//
//   node scripts/emulator-proxy.js <web build folder>

const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.env.EMULATOR_PROXY_PORT ?? 5050);
const PROJECT = process.env.GCLOUD_PROJECT ?? 'demo-chekkin-dev';
const ROOT = path.resolve(process.argv[2] ?? '');
if (!process.argv[2] || !fs.existsSync(path.join(ROOT, 'index.html'))) {
  console.error('Usage: node scripts/emulator-proxy.js <folder with the emulator web build>');
  process.exit(1);
}

// Keep in sync with "emulators" in firebase.json.
const AUTH = 9099;
const FIRESTORE = 8080;
const FUNCTIONS = 5001;

/** The emulator port for a request path, or null to serve the app. */
function emulatorFor(url) {
  if (/^\/(identitytoolkit|securetoken)\.googleapis\.com\//.test(url) ||
      /^\/emulator\/(auth\/|v1\/projects\/[^/]+\/(config|accounts|oobCodes|verificationCodes))/.test(url)) {
    return AUTH;
  }
  if (/^\/google\.firestore\.v1\.Firestore\//.test(url) || url.startsWith('/v1/projects/') ||
      url.startsWith('/emulator/')) {
    return FIRESTORE;
  }
  if (url.startsWith(`/${PROJECT}/`)) return FUNCTIONS;
  return null;
}

const TYPES = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.json': 'application/json', '.wasm': 'application/wasm', '.css': 'text/css', '.png': 'image/png',
  '.jpg': 'image/jpeg', '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.ttf': 'font/ttf',
  '.otf': 'font/otf', '.woff2': 'font/woff2', '.frag': 'text/plain', '.bin': 'application/octet-stream',
};

function serveApp(req, res) {
  const urlPath = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  let file = path.join(ROOT, urlPath);
  if (!file.startsWith(ROOT) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    file = path.join(ROOT, 'index.html'); // the app's own routes
  }
  res.writeHead(200, {
    'Content-Type': TYPES[path.extname(file)] ?? 'application/octet-stream',
    'Cache-Control': 'no-store', // so a rebuild shows up on reload
  });
  fs.createReadStream(file).pipe(res);
}

function forward(req, res, port) {
  const upstream = http.request(
    { host: '127.0.0.1', port, method: req.method, path: req.url, headers: req.headers },
    (upRes) => {
      res.writeHead(upRes.statusCode, upRes.headers);
      upRes.pipe(res); // streamed, for Firestore's long-lived listen requests
    });
  upstream.on('error', (err) => {
    console.error(`Emulator on port ${port} didn't answer ${req.method} ${req.url}: ${err.message}`);
    if (!res.headersSent) res.writeHead(502);
    res.end();
  });
  req.pipe(upstream);
}

http.createServer((req, res) => {
  const port = emulatorFor(req.url);
  if (port) forward(req, res, port);
  else serveApp(req, res);
}).listen(PORT, '0.0.0.0', () => {
  console.log(`\nEmulator app ready at http://localhost:${PORT}` +
    (process.env.CODESPACE_NAME
      ? ` (in Codespaces: https://${process.env.CODESPACE_NAME}-${PORT}.${process.env.GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN ?? 'app.github.dev'})`
      : '') +
    '\nPress Ctrl+C to stop the emulators. Their data is thrown away.');
});
