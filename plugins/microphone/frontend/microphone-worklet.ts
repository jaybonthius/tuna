// The microphone plugin's AudioWorklet: collects the first input
// channel's samples into chunks of `frames` and hands each to the page
// script through its port.

declare class AudioWorkletProcessor {
  readonly port: MessagePort;
  constructor(options?: unknown);
}
declare function registerProcessor(name: string, processor: unknown): void;

type Options = { processorOptions: { frames: number } };

class TunaMicrophone extends AudioWorkletProcessor {
  private readonly frames: number;
  private chunk: Float32Array;
  private filled = 0;

  constructor(options: Options) {
    super(options);
    this.frames = Math.max(128, options.processorOptions.frames);
    this.chunk = new Float32Array(this.frames);
  }

  process(inputs: Float32Array[][]): boolean {
    const input = inputs[0]?.[0];
    if (input === undefined) return true;
    let i = 0;
    while (i < input.length) {
      const n = Math.min(input.length - i, this.frames - this.filled);
      this.chunk.set(input.subarray(i, i + n), this.filled);
      this.filled += n;
      i += n;
      if (this.filled === this.frames) {
        this.port.postMessage(this.chunk, [this.chunk.buffer]);
        this.chunk = new Float32Array(this.frames);
        this.filled = 0;
      }
    }
    return true;
  }
}

registerProcessor("tuna-microphone", TunaMicrophone);
