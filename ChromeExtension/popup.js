const DEFAULT_SETTINGS = { host: "", port: 50002, token: "", mode: "device" };

const hostInput = document.getElementById("host");
const portInput = document.getElementById("port");
const tokenInput = document.getElementById("token");
const modeInputs = document.querySelectorAll('input[name="mode"]');
const statusView = document.getElementById("status");

const ERROR_MESSAGES = {
  auth: "トークンが一致しません。",
  "unknown-host": "sender の --target-host にこの PC のアドレスがありません。",
  "invalid-url": "アドレスが不正です。",
};

function renderStatus(status = { state: "idle" }) {
  statusView.className = "";
  switch (status.state) {
    case "connected":
      statusView.className = "ok";
      statusView.textContent = `接続中: F${12 + status.slot} のreceiver / マイク ${status.mic ? "ON" : "OFF"}（sender の F17 で切替）`;
      break;
    case "connecting":
      statusView.textContent = `接続しています… ${status.url}`;
      break;
    case "reconnecting":
      statusView.className = "error";
      statusView.textContent = `sender に接続できません。再試行中… ${status.url}`;
      break;
    case "unconfigured":
      statusView.className = "error";
      statusView.textContent = "sender のアドレスとトークンを設定してください。";
      break;
    case "error": {
      statusView.className = "error";
      const message = ERROR_MESSAGES[status.reason] ?? `エラー: ${status.reason}`;
      statusView.textContent = status.address ? `${message}（sender から見たアドレス: ${status.address}）` : message;
      break;
    }
    default:
      statusView.textContent = "待機中（会議アプリが仮想マイクを使うと接続します）";
      break;
  }
}

async function load() {
  const settings = await chrome.storage.sync.get(DEFAULT_SETTINGS);
  hostInput.value = settings.host;
  portInput.value = settings.port;
  tokenInput.value = settings.token;
  for (const input of modeInputs) input.checked = input.value === settings.mode;

  const { status } = await chrome.storage.session.get("status");
  renderStatus(status);
}

function save() {
  const port = Number.parseInt(portInput.value, 10);
  chrome.storage.sync.set({
    host: hostInput.value.trim(),
    port: port >= 1 && port <= 65535 ? port : DEFAULT_SETTINGS.port,
    token: tokenInput.value,
    mode: [...modeInputs].find((input) => input.checked)?.value ?? DEFAULT_SETTINGS.mode,
  });
}

for (const input of [hostInput, portInput, tokenInput, ...modeInputs]) {
  input.addEventListener("change", save);
}

document.getElementById("test").addEventListener("click", () => {
  chrome.runtime.sendMessage({ type: "test-connection" });
});

chrome.storage.onChanged.addListener((changes, area) => {
  if (area === "session" && changes.status) renderStatus(changes.status.newValue);
});

load();
