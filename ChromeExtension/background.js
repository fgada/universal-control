// Holds the WebSocket connection to the sender and relays audio frames to tabs
// that are currently capturing the virtual mic.

const DEFAULT_SETTINGS = { host: "", port: 50002, token: "" };
const FRAME_MAGIC = [0x55, 0x43, 0x41, 0x31]; // "UCA1"
const FRAME_HEADER_BYTES = 12;
const CODEC_PCM16_MONO_48K = 1;
const RECONNECT_DELAY_MS = 2000;
const IDLE_CLOSE_DELAY_MS = 5000;
const TEST_CONNECTION_MS = 10000;

const ports = new Set();
let socket = null;
let reconnectTimer = null;
let idleCloseTimer = null;
let testUntil = 0;
let stopReconnecting = false;

chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== "audio") return;

  ports.add(port);
  port.onDisconnect.addListener(() => {
    ports.delete(port);
    scheduleIdleClose();
  });
  stopReconnecting = false;
  ensureConnected();
});

chrome.runtime.onMessage.addListener((message) => {
  if (message?.type === "test-connection") {
    testUntil = Date.now() + TEST_CONNECTION_MS;
    stopReconnecting = false;
    disconnect();
    ensureConnected();
    scheduleIdleClose(TEST_CONNECTION_MS);
  }
});

chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== "sync" || !["host", "port", "token"].some((key) => key in changes)) return;
  stopReconnecting = false;
  disconnect();
  if (wantsConnection()) ensureConnected();
});

chrome.runtime.onStartup.addListener(() => setStatus({ state: "idle" }));
chrome.runtime.onInstalled.addListener(() => setStatus({ state: "idle" }));

function wantsConnection() {
  return ports.size > 0 || Date.now() < testUntil;
}

async function ensureConnected() {
  clearTimeout(idleCloseTimer);
  if (socket || reconnectTimer) return;

  const settings = await chrome.storage.sync.get(DEFAULT_SETTINGS);
  if (socket || !wantsConnection()) return;
  if (!settings.host || !settings.token) {
    setStatus({ state: "unconfigured" });
    return;
  }

  const url = `ws://${formatHost(settings.host)}:${settings.port}`;
  let ws;
  try {
    ws = new WebSocket(url);
  } catch (error) {
    setStatus({ state: "error", reason: "invalid-url", detail: String(error) });
    return;
  }
  ws.binaryType = "arraybuffer";
  socket = ws;
  setStatus({ state: "connecting", url });

  ws.addEventListener("open", () => {
    ws.send(JSON.stringify({ type: "hello", version: 1, token: settings.token }));
  });

  ws.addEventListener("message", (event) => {
    if (typeof event.data === "string") {
      handleControlMessage(event.data);
    } else {
      relayFrame(event.data);
    }
  });

  ws.addEventListener("close", () => {
    if (socket !== ws) return;
    socket = null;
    if (stopReconnecting || !wantsConnection()) {
      if (!stopReconnecting) setStatus({ state: "idle" });
      return;
    }
    setStatus({ state: "reconnecting", url });
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      ensureConnected();
    }, RECONNECT_DELAY_MS);
  });
}

function handleControlMessage(text) {
  let message;
  try {
    message = JSON.parse(text);
  } catch {
    return;
  }

  switch (message.type) {
    case "welcome":
      setStatus({ state: "connected", slot: message.slot, mic: Boolean(message.mic) });
      break;
    case "mic":
      updateStatus({ mic: Boolean(message.active) });
      break;
    case "error":
      // Retrying cannot fix a wrong token or an unregistered receiver address.
      stopReconnecting = true;
      setStatus({ state: "error", reason: message.reason, address: message.address });
      break;
    default:
      break;
  }
}

function relayFrame(buffer) {
  if (buffer.byteLength <= FRAME_HEADER_BYTES) return;
  const bytes = new Uint8Array(buffer);
  if (!FRAME_MAGIC.every((value, index) => bytes[index] === value)) return;
  if (bytes[4] !== 1 || bytes[5] !== CODEC_PCM16_MONO_48K) return;

  // Port messages are JSON-serialized, so binary payloads travel as base64.
  const pcm = base64Encode(bytes.subarray(FRAME_HEADER_BYTES));
  for (const port of ports) {
    port.postMessage({ type: "frame", pcm });
  }
}

function disconnect() {
  clearTimeout(reconnectTimer);
  reconnectTimer = null;
  const ws = socket;
  socket = null;
  ws?.close();
}

function scheduleIdleClose(delay = IDLE_CLOSE_DELAY_MS) {
  clearTimeout(idleCloseTimer);
  idleCloseTimer = setTimeout(() => {
    if (wantsConnection()) return;
    disconnect();
    if (!stopReconnecting) setStatus({ state: "idle" });
  }, delay);
}

function formatHost(host) {
  return host.includes(":") && !host.startsWith("[") ? `[${host}]` : host;
}

function base64Encode(bytes) {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

let currentStatus = { state: "idle" };

function setStatus(status) {
  currentStatus = { ...status, updatedAt: Date.now() };
  chrome.storage.session.set({ status: currentStatus });
}

function updateStatus(partial) {
  setStatus({ ...currentStatus, ...partial });
}
