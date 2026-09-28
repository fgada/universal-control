// Plays PCM frames from the sender through a small jitter buffer.
// Keep JitterBuffer in sync with the ScriptProcessor fallback in inject.js.

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

    // Drop the backlog when latency has crept up (burst after a stall, clock drift).
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

class UniversalControlMicPlayer extends AudioWorkletProcessor {
  constructor() {
    super();
    this.buffer = new JitterBuffer(sampleRate);
    this.port.onmessage = (event) => this.buffer.write(new Int16Array(event.data));
  }

  process(_inputs, outputs) {
    const channel = outputs[0][0];
    if (channel) this.buffer.read(channel);
    return true;
  }
}

registerProcessor("uc-mic-player", UniversalControlMicPlayer);
