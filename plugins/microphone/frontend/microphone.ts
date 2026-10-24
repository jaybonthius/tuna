import { action, getPath } from "datastar";

// The microphone plugin's page script: captures the tab's microphone when
// the server's one-time instruction microphoneStart says so, and posts the
// audio to the plugin's page address as float32 little-endian mono samples
// at the rate the server asked for, about every chunk samples, one post at
// a time so that the server receives them in order. microphoneStop ends
// it. What keeps the page from capturing goes to the problem address.

type Start = Readonly<{ rate: number; chunk: number }>;

type Problem = "insecure" | "unavailable" | "denied" | "no-microphone" | "error";

type Capture = {
  stream: MediaStream;
  context: AudioContext;
};

let capture: Capture | null = null;
// Counts starts and stops, so a start still waiting for the browser
// learns that a newer instruction replaced it.
let generation = 0;

action({
  name: "microphoneStart",
  apply(_context: unknown, start: Start): void {
    void startCapture(start);
  },
});

action({
  name: "microphoneStop",
  apply(): void {
    generation += 1;
    stopCapture();
  },
});

function post(name: string, body: Uint8Array): Promise<unknown> {
  return fetch(`/plugin/microphone/${name}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/octet-stream",
      "Tuna-Tab": String(getPath("tab")),
    },
    body,
  }).catch(() => undefined);
}

function report(problem: Problem, name?: string): void {
  void post("problem", new TextEncoder().encode(JSON.stringify({ problem, name })));
}

function errorName(error: unknown): string {
  const name = (error as { name?: unknown } | null)?.name;
  return typeof name === "string" && /^[A-Za-z]{1,64}$/.test(name) ? name : "Error";
}

function stopCapture(): void {
  if (capture === null) return;
  for (const track of capture.stream.getTracks()) track.stop();
  void capture.context.close();
  capture = null;
  pending = [];
}

// An AudioContext at RATE and the stream's source in it, or, where the
// browser cannot connect a microphone to a context at another rate than
// its own (Firefox), a context at the browser's rate.
function openContext(stream: MediaStream, rate: number): [AudioContext, MediaStreamAudioSourceNode] {
  try {
    const context = new AudioContext({ sampleRate: rate });
    try {
      return [context, context.createMediaStreamSource(stream)];
    } catch (error) {
      void context.close();
      throw error;
    }
  } catch {
    const context = new AudioContext();
    return [context, context.createMediaStreamSource(stream)];
  }
}

async function startCapture(start: Start): Promise<void> {
  generation += 1;
  const mine = generation;
  stopCapture();
  if (!window.isSecureContext) return report("insecure");
  if (navigator.mediaDevices?.getUserMedia === undefined || typeof AudioWorkletNode === "undefined") {
    return report("unavailable");
  }
  let stream: MediaStream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({
      audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true },
    });
  } catch (error) {
    const name = errorName(error);
    if (name === "NotAllowedError" || name === "SecurityError") return report("denied", name);
    if (name === "NotFoundError" || name === "OverconstrainedError") return report("no-microphone", name);
    return report("error", name);
  }
  if (mine !== generation) {
    for (const track of stream.getTracks()) track.stop();
    return;
  }
  let context: AudioContext | null = null;
  try {
    const [opened, source] = openContext(stream, start.rate);
    context = opened;
    await context.audioWorklet.addModule(new URL("./microphone-worklet.js", import.meta.url));
    await context.resume();
    if (mine !== generation) throw new Error("replaced");
    const node = new AudioWorkletNode(context, "tuna-microphone", {
      numberOfInputs: 1,
      numberOfOutputs: 1,
      channelCount: 1,
      channelCountMode: "explicit",
      processorOptions: { frames: Math.round((context.sampleRate * start.chunk) / start.rate) },
    });
    const resampler = new Resampler(context.sampleRate, start.rate);
    node.port.onmessage = (event: MessageEvent<Float32Array>) => {
      if (mine === generation) send(resampler.push(event.data));
    };
    source.connect(node);
    // Its output is silence; connecting it keeps the graph pulling it.
    node.connect(context.destination);
    capture = { stream, context };
  } catch (error) {
    for (const track of stream.getTracks()) track.stop();
    if (context !== null) void context.close();
    if (mine === generation) report("error", errorName(error));
  }
}

// Samples waiting to be posted, and whether a post is on its way: one at
// a time, so chunks arrive in order; what waits meanwhile goes together.
let pending: Float32Array[] = [];
let sending = false;

function send(samples: Float32Array): void {
  if (samples.length === 0) return;
  pending.push(samples);
  if (!sending) void sendPending();
}

async function sendPending(): Promise<void> {
  sending = true;
  while (pending.length > 0) {
    const batch = pending;
    pending = [];
    const count = batch.reduce((sum, samples) => sum + samples.length, 0);
    const bytes = new Uint8Array(count * 4);
    const view = new DataView(bytes.buffer);
    let offset = 0;
    for (const samples of batch) {
      for (const sample of samples) {
        view.setFloat32(offset, sample, true);
        offset += 4;
      }
    }
    await post("chunk", bytes);
  }
  sending = false;
}

// Linear interpolation from one sample rate to another, across chunks.
// Its input is read as one sequence: the previous chunk's last sample at
// index 0, then the chunk.
class Resampler {
  private readonly step: number;
  private position = 0;
  private previous = 0;

  constructor(from: number, to: number) {
    this.step = from / to;
  }

  push(input: Float32Array): Float32Array {
    if (this.step === 1 || input.length === 0) return input;
    const output: number[] = [];
    let p = this.position;
    while (p < input.length) {
      const i = Math.floor(p);
      const a = i === 0 ? this.previous : input[i - 1];
      const b = input[i];
      output.push(a + (b - a) * (p - i));
      p += this.step;
    }
    this.position = p - input.length;
    this.previous = input[input.length - 1];
    return Float32Array.from(output);
  }
}
