/**
 * Seahelm Watch HTTP gateway — thin adapter in front of EMQX.
 *
 *   GET  /api/health
 *   GET  /api/v1/sync?mac_id=&after=   → retained snapshot + events since cursor
 *   POST /api/v1/publish               → { topic, payload, qos?, retain? }
 *
 * Auth: Authorization: Bearer <WATCH_API_KEY>  (or X-Api-Key)
 */
import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { cors } from "hono/cors";
import mqtt, { type IPublishPacket, type MqttClient } from "mqtt";

const PORT = Number(process.env.PORT ?? 3000);
const MQTT_URL = process.env.MQTT_URL ?? "mqtt://emqx:1883";
const MQTT_USERNAME = process.env.MQTT_USERNAME || undefined;
const MQTT_PASSWORD = process.env.MQTT_PASSWORD || undefined;
const MQTT_SUBSCRIBE = process.env.MQTT_SUBSCRIBE ?? "seahelm/#";
const API_KEY = process.env.WATCH_API_KEY ?? "";
const EVENT_BUFFER = Number(process.env.EVENT_BUFFER ?? 2000);

/** topic → latest retained payload (empty payload tombstones delete the entry). */
const retained = new Map<string, string>();

/** Ring buffer of non-retain (and retain) publishes for Watch polling. */
type BusEvent = { seq: number; topic: string; payload: string; retain: boolean };
const events: BusEvent[] = [];
let seq = 0;

let mqttReady = false;
let lastMqttError: string | null = null;

function pushEvent(topic: string, payload: string, retain: boolean) {
  seq += 1;
  events.push({ seq, topic, payload, retain });
  while (events.length > EVENT_BUFFER) events.shift();
}

function connectMqtt(): MqttClient {
  const client = mqtt.connect(MQTT_URL, {
    username: MQTT_USERNAME,
    password: MQTT_PASSWORD,
    reconnectPeriod: 3000,
    connectTimeout: 15_000,
    clean: true,
    clientId: `seahelm-gw-${Math.random().toString(16).slice(2, 10)}`,
  });

  client.on("connect", () => {
    mqttReady = true;
    lastMqttError = null;
    console.log(`[gw] mqtt connected ${MQTT_URL}, sub ${MQTT_SUBSCRIBE}`);
    client.subscribe(MQTT_SUBSCRIBE, { qos: 1 }, (err) => {
      if (err) console.error("[gw] subscribe failed", err);
    });
  });

  client.on("reconnect", () => {
    mqttReady = false;
    console.log("[gw] mqtt reconnecting…");
  });

  client.on("error", (err) => {
    lastMqttError = err.message;
    console.error("[gw] mqtt error", err.message);
  });

  client.on("close", () => {
    mqttReady = false;
  });

  client.on("message", (topic, payloadBuf, packet: IPublishPacket) => {
    const payload = payloadBuf.toString("utf8");
    const retain = Boolean(packet.retain);

    if (retain) {
      if (payloadBuf.length === 0) retained.delete(topic);
      else retained.set(topic, payload);
    }

    // Always record for pollers (pair/grant, reply, events, retained updates).
    pushEvent(topic, payload, retain);
  });

  return client;
}

const bus = connectMqtt();

const app = new Hono();
app.use("*", cors());

function authorized(c: { req: { header: (n: string) => string | undefined } }): boolean {
  if (!API_KEY) return false;
  const bearer = c.req.header("authorization");
  if (bearer?.toLowerCase().startsWith("bearer ")) {
    return bearer.slice(7).trim() === API_KEY;
  }
  return c.req.header("x-api-key") === API_KEY;
}

function underMac(topic: string, macId: string): boolean {
  const prefix = `seahelm/${macId}/`;
  return topic === `seahelm/${macId}` || topic.startsWith(prefix);
}

app.get("/api/health", (c) =>
  c.json({
    ok: true,
    mqtt: mqttReady,
    retained: retained.size,
    events: events.length,
    cursor: seq,
    error: lastMqttError,
  }),
);

/** @deprecated prefer /api/v1/sync */
app.get("/api/v1/snapshot", (c) => {
  if (!authorized(c)) return c.json({ ok: false, error: "unauthorized" }, 401);
  const macId = (c.req.query("mac_id") ?? "").trim();
  if (!macId) return c.json({ ok: false, error: "mac_id required" }, 400);

  const messages: Record<string, string> = {};
  for (const [topic, payload] of retained) {
    if (underMac(topic, macId)) messages[topic] = payload;
  }
  return c.json({
    ok: true,
    mac_id: macId,
    mqtt: mqttReady,
    count: Object.keys(messages).length,
    messages,
  });
});

/**
 * One round-trip for Watch: full retained map for mac_id + events with seq > after.
 * Pass after=0 (or omit) on first connect; then use returned `cursor`.
 */
app.get("/api/v1/sync", (c) => {
  if (!authorized(c)) return c.json({ ok: false, error: "unauthorized" }, 401);
  if (!mqttReady) return c.json({ ok: false, error: "mqtt not connected" }, 503);

  const macId = (c.req.query("mac_id") ?? "").trim();
  if (!macId) return c.json({ ok: false, error: "mac_id required" }, 400);
  const after = Number(c.req.query("after") ?? 0);

  const messages: Record<string, string> = {};
  for (const [topic, payload] of retained) {
    if (underMac(topic, macId)) messages[topic] = payload;
  }

  const ev = events
    .filter((e) => e.seq > after && underMac(e.topic, macId))
    .map((e) => ({ seq: e.seq, topic: e.topic, payload: e.payload, retain: e.retain }));

  return c.json({
    ok: true,
    mac_id: macId,
    mqtt: mqttReady,
    cursor: seq,
    count: Object.keys(messages).length,
    messages,
    events: ev,
  });
});

app.post("/api/v1/publish", async (c) => {
  if (!authorized(c)) return c.json({ ok: false, error: "unauthorized" }, 401);
  if (!mqttReady) return c.json({ ok: false, error: "mqtt not connected" }, 503);

  let body: {
    topic?: string;
    payload?: string;
    qos?: number;
    retain?: boolean;
  };
  try {
    body = await c.req.json();
  } catch {
    return c.json({ ok: false, error: "invalid json" }, 400);
  }

  const topic = (body.topic ?? "").trim();
  if (!topic.startsWith("seahelm/")) {
    return c.json({ ok: false, error: "topic must start with seahelm/" }, 400);
  }
  if (typeof body.payload !== "string") {
    return c.json({ ok: false, error: "payload string required" }, 400);
  }

  const qos = ([0, 1, 2].includes(body.qos as number) ? body.qos : 1) as 0 | 1 | 2;
  const retain = Boolean(body.retain);

  try {
    await new Promise<void>((resolve, reject) => {
      bus.publish(topic, body.payload!, { qos, retain }, (err) => {
        if (err) reject(err);
        else resolve();
      });
    });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return c.json({ ok: false, error: msg }, 500);
  }

  if (retain) {
    if (body.payload.length === 0) retained.delete(topic);
    else retained.set(topic, body.payload);
  }
  pushEvent(topic, body.payload, retain);

  return c.json({ ok: true, topic, retain, qos });
});

serve({ fetch: app.fetch, port: PORT, hostname: "0.0.0.0" }, (info) => {
  console.log(`[gw] http :${info.port}  mqtt→${MQTT_URL}`);
});
