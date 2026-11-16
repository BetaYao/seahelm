// A Cloudflare Worker that forwards the Telegram Bot API, for a machine
// whose network cannot reach api.telegram.org. seahelm-gateway uses it when
// Settings ▸ Telegram ▸ API URL (gateway config `telegram.api_url`) is set to
// the Worker's address.
//
// It forwards only Bot API paths (`/bot<token>/<method>` and
// `/file/bot<token>/<path>`), unchanged — method, headers, body, and the
// long poll's held-open response — so it is not an open proxy. The bot token
// is in the path, as Telegram wants it; the Worker neither logs nor keeps it.
//
// Deploy (needs wrangler and a Cloudflare account):
//
//   npx wrangler deploy scripts/telegram-proxy-worker.js \
//       --name seahelm-telegram-api --compatibility-date 2026-11-01
//
// In mainland China *.workers.dev is not reachable either, so give the Worker
// a custom domain on a zone you have in Cloudflare (Workers ▸ the worker ▸
// Settings ▸ Domains & Routes ▸ Add ▸ Custom domain, e.g.
// tg-api.example.com), then set that as the API URL:
//
//   https://tg-api.example.com
//
// Check it from the machine running seahelm-gateway:
//
//   curl https://tg-api.example.com/bot<token>/getMe

const UPSTREAM = 'https://api.telegram.org';
const ALLOWED = /^\/(file\/)?bot\d+:[A-Za-z0-9_-]+(\/|$)/;

export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (!ALLOWED.test(url.pathname)) {
      return new Response('Not found\n', { status: 404 });
    }
    const headers = new Headers(request.headers);
    // Cloudflare's own and the client's hop headers mean nothing to Telegram.
    for (const h of ['host', 'cf-connecting-ip', 'cf-ipcountry', 'cf-ray', 'cf-visitor', 'x-forwarded-for', 'x-real-ip']) {
      headers.delete(h);
    }
    const hasBody = request.method !== 'GET' && request.method !== 'HEAD';
    return fetch(UPSTREAM + url.pathname + url.search, {
      method: request.method,
      headers,
      body: hasBody ? request.body : undefined,
      redirect: 'manual',
    });
  },
};
