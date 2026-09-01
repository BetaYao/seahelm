// bench-collector.js — catches what bench.html posts back.
//
// The page measures the device it runs on; this is how the numbers get off that
// device. Open the benchmark on the phone with `?report=` pointed here and the
// results arrive in this terminal — no cable, no remote debugger, and no reading
// four columns off a phone screen into a notebook.
//
//   node devbroker/bench-collector.js            # listens on 0.0.0.0:28099
//   → on the phone, over the tunnel:
//     https://gw.seahelm.dev/bench.html?report=http://<mac-lan-ip>:28099/
//
// That URL resolves only while the gateway is serving a tree that contains
// bench.html, and a release bundle has no reason to carry a benchmark page — so
// do not assume the shipped app serves one. Point `host_gateway.web_root` in
// ~/.config/seahelm/config.json at this working copy and the gateway serves the
// files from here instead of from the bundle. That is what you want while
// iterating anyway: edits land without a rebuild.
//
// The phone must be able to reach the Mac for the POST — same LAN is simplest.
// If it cannot, the page still shows everything on screen; this is convenience.
'use strict';

const http = require('http');
const os = require('os');

const PORT = Number(process.env.PORT || 28099);

function lanAddresses() {
  const out = [];
  for (const list of Object.values(os.networkInterfaces())) {
    for (const i of list || []) {
      if (i.family === 'IPv4' && !i.internal) out.push(i.address);
    }
  }
  return out;
}

http.createServer((req, res) => {
  // The page posts cross-origin, so the preflight has to pass before anything
  // arrives — a collector that only handles POST silently receives nothing.
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', '*');
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }
  if (req.method !== 'POST') { res.writeHead(200); res.end('bench collector\n'); return; }

  let body = '';
  req.on('data', (c) => { body += c; if (body.length > 1 << 20) req.destroy(); });
  req.on('end', () => {
    const ua = req.headers['user-agent'] || '(no ua)';
    const from = req.socket.remoteAddress || '?';
    console.log(`\n${'─'.repeat(72)}`);
    console.log(`${new Date().toISOString()}  from ${from}`);
    console.log(ua);
    console.log(`${'─'.repeat(72)}`);
    console.log(body);
    res.writeHead(204); res.end();
  });
}).listen(PORT, '0.0.0.0', () => {
  console.log(`bench collector on :${PORT}`);
  for (const a of lanAddresses()) {
    console.log(`  https://gw.seahelm.dev/bench.html?report=http://${a}:${PORT}/`);
  }
  console.log('\nwaiting…');
});
