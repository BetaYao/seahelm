# Seahelm edge stack (`gw.seahelm.dev`)

Self-hosted: **Caddy** + **EMQX** + **TS gateway** (Watch HTTP) + **seahelm-web**.

## Local test with Cloudflare Tunnel (recommended first)

TLS stays on Cloudflare; this Mac only serves HTTP on `:80`.

```bash
# one-time
brew install cloudflared          # already ok if `cloudflared version` works
cloudflared tunnel login
cloudflared tunnel create seahelm-gw
cloudflared tunnel route dns seahelm-gw gw.seahelm.dev
# note the credentials JSON path printed above

cp cloudflared.yml.example cloudflared.yml
# edit credentials-file: → that JSON path

cp .env.example .env              # set WATCH_API_KEY
docker compose -f docker-compose.yml -f docker-compose.tunnel.yml up -d --build
cloudflared tunnel --config cloudflared.yml run
```

Then:

```bash
curl -sS -H "Authorization: Bearer $WATCH_API_KEY" \
  'https://gw.seahelm.dev/api/health'
```

Watch / web use `https://gw.seahelm.dev` as usual. Leave `cloudflared` running while testing.

Cloudflare Dashboard → domain SSL/TLS mode: **Full** is fine (tunnel speaks HTTP to origin; CF still shows HTTPS to clients).

## Production (VPS, Caddy auto-HTTPS)

Point `gw.seahelm.dev` A/AAAA at the server, then:

```bash
cd clients/seahelm-stack
cp .env.example .env
docker compose up -d --build
```

- Web UI: `https://gw.seahelm.dev/`
- Watch API: `https://gw.seahelm.dev/api/v1/…`
- WSS (web/Mac): `wss://gw.seahelm.dev/mqtt`
- Dashboard (local only): `http://127.0.0.1:18083` (admin / `EMQX_DASHBOARD_PASSWORD`)

## EMQX auth (first time)

Fresh EMQX allows connections with no authenticator (easy bring-up). After smoke-test:

1. Dashboard → **Authentication** → add `password_based` / built-in DB.
2. Create user matching `MQTT_USERNAME` / `MQTT_PASSWORD` in `.env`.
3. `docker compose restart gateway` (and point Mac at the same user).
4. Add ACL (`seahelm/{mac_id}/#`) when you lock it down.

## Watch API

```bash
# Sync retained + events (Watch polls this every ~2s)
curl -sS -H "Authorization: Bearer $WATCH_API_KEY" \
  'https://gw.seahelm.dev/api/v1/sync?mac_id=live&after=0' | jq .

# Publish (e.g. pair claim / command)
curl -sS -X POST -H "Authorization: Bearer $WATCH_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"topic":"seahelm/live/command","payload":"{}","qos":1,"retain":false}' \
  https://gw.seahelm.dev/api/v1/publish
```

Watch app: set build setting `SEAHELM_GATEWAY_API_KEY` to the same value as `.env` `WATCH_API_KEY` (Info.plist expands `$(SEAHELM_GATEWAY_API_KEY)`).

## Mac

Point Seahelm MQTT at `wss://gw.seahelm.dev/mqtt` with the same broker user (or keep `mqtt://host:1883` on LAN).

## Layout

```
clients/seahelm-stack/
  docker-compose.yml          # caddy + emqx + gateway
  docker-compose.tunnel.yml   # local CF Tunnel (HTTP :80 only)
  Caddyfile                   # production auto-HTTPS
  Caddyfile.tunnel            # tunnel origin (HTTP)
  cloudflared.yml.example
  gateway/                    # Hono + mqtt.js (TypeScript)
  ../seahelm-web/             # mounted read-only as the static site
```
