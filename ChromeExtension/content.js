// Bridges inject.js (page's MAIN world) and the service worker.
// Only holds a port to the service worker while the page is capturing the virtual mic.

(() => {
  const PAGE_SOURCE = "uc-mic:page";
  const EXTENSION_SOURCE = "uc-mic:ext";
  const PORT_RETRY_MS = 1000;

  let capturing = false;
  let port = null;

  function postToPage(message, transfer = []) {
    window.postMessage({ source: EXTENSION_SOURCE, ...message }, "*", transfer);
  }

  async function sendConfig() {
    try {
      const { mode } = await chrome.storage.sync.get({ mode: "device" });
      postToPage({ type: "config", mode, workletUrl: chrome.runtime.getURL("worklet.js") });
    } catch {
      // Extension was reloaded; this content script is orphaned.
    }
  }

  function connectPort() {
    if (port || !capturing) return;
    try {
      port = chrome.runtime.connect({ name: "audio" });
    } catch {
      return;
    }

    port.onMessage.addListener((message) => {
      if (message.type !== "frame") return;
      const buffer = base64Decode(message.pcm);
      postToPage({ type: "frame", buffer }, [buffer]);
    });
    port.onDisconnect.addListener(() => {
      port = null;
      // The service worker was restarted; reconnect while still capturing.
      if (capturing) setTimeout(connectPort, PORT_RETRY_MS);
    });
  }

  function disconnectPort() {
    port?.disconnect();
    port = null;
  }

  function base64Decode(text) {
    const binary = atob(text);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes.buffer;
  }

  window.addEventListener("message", (event) => {
    if (event.source !== window || event.data?.source !== PAGE_SOURCE) return;

    switch (event.data.type) {
      case "hello":
        sendConfig();
        break;
      case "capture":
        capturing = Boolean(event.data.active);
        if (capturing) {
          connectPort();
        } else {
          disconnectPort();
        }
        break;
      default:
        break;
    }
  });

  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === "sync" && "mode" in changes) sendConfig();
  });

  sendConfig();
})();
