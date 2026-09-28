// Runs in the page's MAIN world at document_start, before the meeting app's own
// scripts, and exposes the sender's mic as an extra audio input device.

(() => {
  if (!window.MediaDevices || !navigator.mediaDevices) return;

  const installedKey = Symbol.for("universal-control-mic.installed");
  if (window[installedKey]) return;
  Object.defineProperty(window, installedKey, { value: true });

  const PAGE_SOURCE = "uc-mic:page";
  const EXTENSION_SOURCE = "uc-mic:ext";
  const VIRTUAL_DEVICE_ID = "universal-control-mic";
  const VIRTUAL_GROUP_ID = "universal-control";
  const VIRTUAL_LABEL = "Universal Control Mic";
  const SAMPLE_RATE = 48000;
  const CONFIG_TIMEOUT_MS = 1000;

  const mediaDevicesPrototype = MediaDevices.prototype;
  const originalGetUserMedia = mediaDevicesPrototype.getUserMedia;
  const originalEnumerateDevices = mediaDevicesPrototype.enumerateDevices;

  // MARK: - Config from content.js

  let config = null;
  let resolveConfig;
  const configReady = new Promise((resolve) => {
    resolveConfig = resolve;
  });
  setTimeout(() => {
    if (!config) applyConfig({ mode: "device", workletUrl: null });
  }, CONFIG_TIMEOUT_MS);

  function applyConfig(next) {
    const previousMode = config?.mode;
    config = { mode: next.mode === "replace" ? "replace" : "device", workletUrl: next.workletUrl ?? config?.workletUrl ?? null };
    resolveConfig();
    if (previousMode && previousMode !== config.mode) {
      navigator.mediaDevices.dispatchEvent(new Event("devicechange"));
    }
  }

  function postToExtension(message) {
    window.postMessage({ source: PAGE_SOURCE, ...message }, "*");
  }

  window.addEventListener("message", (event) => {
    if (event.source !== window || event.data?.source !== EXTENSION_SOURCE) return;
    // Keep bridge traffic away from the page's own message handlers.
    event.stopImmediatePropagation();

    switch (event.data.type) {
      case "config":
        applyConfig(event.data);
        break;
      case "frame":
        engine.push(event.data.buffer);
        break;
      default:
        break;
    }
  });

  postToExtension({ type: "hello" });

  // MARK: - Audio engine

  // Keep in sync with worklet.js; used only when the worklet cannot be loaded.
  class JitterBuffer {
    constructor(rate) {
      this.samples = new Float32Array(rate);
      this.readIndex = 0;
      this.writeIndex = 0;
      this.size = 0;
      this.targetSize = Math.round(rate * 0.06);
      this.maximumSize = Math.round(rate * 0.25);
      this.playing = false;
    }

    write(pcm) {
      const capacity = this.samples.length;
      for (let i = 0; i < pcm.length; i += 1) {
        if (this.size === capacity) {
          this.readIndex = (this.readIndex + 1) % capacity;
          this.size -= 1;
        }
        this.samples[this.writeIndex] = pcm[i] / 32768;
        this.writeIndex = (this.writeIndex + 1) % capacity;
        this.size += 1;
      }
      if (this.size > this.maximumSize) {
        const excess = this.size - this.targetSize;
        this.readIndex = (this.readIndex + excess) % capacity;
        this.size = this.targetSize;
      }
    }

    read(output) {
      if (!this.playing) {
        if (this.size < this.targetSize) {
          output.fill(0);
          return;
        }
        this.playing = true;
      }
      const capacity = this.samples.length;
      for (let i = 0; i < output.length; i += 1) {
        if (this.size === 0) {
          output.fill(0, i);
          this.playing = false;
          return;
        }
        output[i] = this.samples[this.readIndex];
        this.readIndex = (this.readIndex + 1) % capacity;
        this.size -= 1;
      }
    }
  }

  const engine = {
    context: null,
    destination: null,
    sendPCM: null,
    ready: null,
    activeTracks: 0,

    ensure() {
      this.ready ??= this.build();
      return this.ready;
    },

    async build() {
      const context = new AudioContext({ sampleRate: SAMPLE_RATE, latencyHint: "interactive" });
      const destination = context.createMediaStreamDestination();
      destination.channelCount = 1;

      let source = null;
      if (config.workletUrl) {
        try {
          await context.audioWorklet.addModule(config.workletUrl);
          source = new AudioWorkletNode(context, "uc-mic-player", {
            numberOfInputs: 0,
            numberOfOutputs: 1,
            outputChannelCount: [1],
          });
          this.sendPCM = (buffer) => source.port.postMessage(buffer, [buffer]);
        } catch (error) {
          console.warn("[Universal Control Mic] AudioWorklet unavailable; using ScriptProcessor", error);
        }
      }
      if (!source) {
        const jitterBuffer = new JitterBuffer(SAMPLE_RATE);
        source = context.createScriptProcessor(1024, 1, 1);
        source.onaudioprocess = (event) => jitterBuffer.read(event.outputBuffer.getChannelData(0));
        this.sendPCM = (buffer) => jitterBuffer.write(new Int16Array(buffer));
      }

      source.connect(destination);
      this.context = context;
      this.destination = destination;
      installResumeOnGesture(context);
    },

    push(buffer) {
      if (this.activeTracks > 0 && this.sendPCM) this.sendPCM(buffer);
    },

    async createTrack() {
      await configReady;
      await this.ensure();
      const track = this.destination.stream.getAudioTracks()[0].clone();
      return decorateTrack(track);
    },

    acquire() {
      this.activeTracks += 1;
      if (this.activeTracks === 1) {
        this.context.resume().catch(() => {});
        postToExtension({ type: "capture", active: true });
      }
    },

    release() {
      this.activeTracks = Math.max(0, this.activeTracks - 1);
      if (this.activeTracks === 0) {
        postToExtension({ type: "capture", active: false });
        this.context.suspend().catch(() => {});
      }
    },
  };

  // Autoplay policy can leave the context suspended until the user interacts.
  function installResumeOnGesture(context) {
    const resume = () => {
      if (engine.activeTracks > 0 && context.state === "suspended") {
        context.resume().catch(() => {});
      }
    };
    for (const type of ["pointerdown", "keydown"]) {
      window.addEventListener(type, resume, { capture: true, passive: true });
    }
  }

  function decorateTrack(track) {
    const originalStop = track.stop.bind(track);
    const originalClone = track.clone.bind(track);
    const originalGetSettings = track.getSettings.bind(track);
    const originalGetCapabilities = track.getCapabilities?.bind(track);
    let stopped = false;

    const release = () => {
      if (stopped) return;
      stopped = true;
      engine.release();
    };

    Object.defineProperties(track, {
      label: { value: VIRTUAL_LABEL, configurable: true },
      stop: {
        value() {
          release();
          originalStop();
        },
        configurable: true,
      },
      clone: {
        value() {
          return decorateTrack(originalClone());
        },
        configurable: true,
      },
      getSettings: {
        value() {
          return { ...originalGetSettings(), deviceId: VIRTUAL_DEVICE_ID, groupId: VIRTUAL_GROUP_ID };
        },
        configurable: true,
      },
      getCapabilities: {
        value() {
          return { ...(originalGetCapabilities?.() ?? {}), deviceId: VIRTUAL_DEVICE_ID, groupId: VIRTUAL_GROUP_ID };
        },
        configurable: true,
      },
      // Echo cancellation / noise suppression constraints cannot apply to a
      // synthesized track; accept them rather than failing the app's call.
      applyConstraints: {
        value: async () => {},
        configurable: true,
      },
    });
    track.addEventListener("ended", release);

    engine.acquire();
    return track;
  }

  // MARK: - MediaDevices patches

  function requestedDeviceIds(audio) {
    const ids = [];
    const add = (value) => {
      if (value == null) return;
      if (typeof value === "string") ids.push(value);
      else if (Array.isArray(value)) value.forEach(add);
      else if (typeof value === "object") {
        add(value.exact);
        add(value.ideal);
      }
    };
    if (audio && typeof audio === "object") {
      add(audio.deviceId);
      (audio.advanced ?? []).forEach((set) => add(set?.deviceId));
    }
    return ids;
  }

  function wantsVirtualMic(constraints) {
    if (!constraints?.audio) return false;
    return config.mode === "replace" || requestedDeviceIds(constraints.audio).includes(VIRTUAL_DEVICE_ID);
  }

  function virtualDeviceInfo() {
    const prototype = (window.InputDeviceInfo ?? window.MediaDeviceInfo).prototype;
    const fields = { deviceId: VIRTUAL_DEVICE_ID, kind: "audioinput", label: VIRTUAL_LABEL, groupId: VIRTUAL_GROUP_ID };
    return Object.create(prototype, {
      deviceId: { value: fields.deviceId, enumerable: true },
      kind: { value: fields.kind, enumerable: true },
      label: { value: fields.label, enumerable: true },
      groupId: { value: fields.groupId, enumerable: true },
      toJSON: { value: () => ({ ...fields }) },
      getCapabilities: {
        value: () => ({
          deviceId: VIRTUAL_DEVICE_ID,
          groupId: VIRTUAL_GROUP_ID,
          channelCount: { min: 1, max: 1 },
          sampleRate: { min: SAMPLE_RATE, max: SAMPLE_RATE },
          sampleSize: { min: 16, max: 16 },
          echoCancellation: [false],
          autoGainControl: [false],
          noiseSuppression: [false],
        }),
      },
    });
  }

  mediaDevicesPrototype.getUserMedia = async function getUserMedia(constraints) {
    await configReady;
    if (!wantsVirtualMic(constraints)) {
      return originalGetUserMedia.call(this, constraints);
    }

    const videoTracks = constraints.video
      ? (await originalGetUserMedia.call(this, { video: constraints.video })).getVideoTracks()
      : [];
    const audioTrack = await engine.createTrack();
    return new MediaStream([audioTrack, ...videoTracks]);
  };

  mediaDevicesPrototype.enumerateDevices = async function enumerateDevices() {
    const devices = await originalEnumerateDevices.call(this);
    await configReady;
    const virtualDevice = virtualDeviceInfo();
    // In replace mode, list it first so apps that pick the first input choose it.
    return config.mode === "replace" ? [virtualDevice, ...devices] : [...devices, virtualDevice];
  };
})();
