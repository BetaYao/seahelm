// broker.js — local dev broker: MQTT tcp + MQTT-over-WS (path /mqtt or any).
// Retained + LWT via aedes. Uses websocket-stream (aedes canonical WS recipe).
// Ports deliberately avoid the seahelm-stack EMQX mapping (host 1883 / 8083).
const aedes = require('aedes')();
const net = require('net');
const http = require('http');
const wsStream = require('websocket-stream');

const MQTT_PORT = Number(process.env.MQTT_PORT || 2883);
const WS_PORT = Number(process.env.WS_PORT || 28083);

net.createServer(aedes.handle).listen(MQTT_PORT, () =>
  console.log(`[devbroker] MQTT tcp    → mqtt://localhost:${MQTT_PORT}`));

const httpServer = http.createServer();
wsStream.createServer({ server: httpServer }, aedes.handle);
httpServer.listen(WS_PORT, () =>
  console.log(`[devbroker] MQTT over WS → ws://localhost:${WS_PORT}/mqtt`));

aedes.on('client', c => console.log(`[devbroker] + client ${c.id}`));
aedes.on('clientDisconnect', c => console.log(`[devbroker] - client ${c.id}`));
aedes.on('publish', (p, c) => { if (c) console.log(`[devbroker] pub ${p.topic} retain=${p.retain} by ${c.id}`); });
