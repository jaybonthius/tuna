import { action } from "datastar";

type Keydown = Readonly<{
  version: 1;
  type: "keydown";
  clientId: string;
  sequence: number;
  key: string;
  code: string;
  location: number;
  repeat: boolean;
  isComposing: boolean;
  altKey: boolean;
  ctrlKey: boolean;
  metaKey: boolean;
  shiftKey: boolean;
}>;

// One id per browser tab: sessionStorage is per tab and survives reloads.
const clientIdKey = "tunaClientId";
const sequenceKey = "tunaSequence";

function loadClientId(): string {
  const stored = sessionStorage.getItem(clientIdKey);
  if (stored !== null) return stored;
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  const id = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  sessionStorage.setItem(clientIdKey, id);
  return id;
}

// Sequence numbers keep increasing across reloads of the same tab.
function nextSequence(): number {
  const sequence = Number(sessionStorage.getItem(sequenceKey) ?? "0") + 1;
  sessionStorage.setItem(sequenceKey, String(sequence));
  return sequence;
}

const client = loadClientId();
const queue: Keydown[] = [];
let draining = false;

async function drainQueue(): Promise<void> {
  if (draining) return;
  draining = true;
  try {
    while (queue.length !== 0) {
      try {
        const response = await fetch("/commands", {
          method: "POST",
          credentials: "same-origin",
          headers: {
            "Content-Type": "application/json",
            "Datastar-Request": "true",
          },
          body: JSON.stringify(queue[0]),
        });
        if (response.status !== 204) {
          console.error("Tuna keydown was not accepted", response.status);
        }
      } catch (error) {
        console.error("Tuna keydown transport failed", error);
      } finally {
        // A failed response does not prove the command was not executed.
        queue.shift();
      }
    }
  } finally {
    draining = false;
  }
}

action({
  name: "tunaKeyboard",
  apply({ evt }: { evt?: Event }): void {
    if (!(evt instanceof KeyboardEvent) || evt.type !== "keydown") return;
    if (!evt.isComposing) evt.preventDefault();
    queue.push(Object.freeze({
      version: 1,
      type: "keydown",
      clientId: client,
      sequence: nextSequence(),
      key: evt.key,
      code: evt.code,
      location: evt.location,
      repeat: evt.repeat,
      isComposing: evt.isComposing,
      altKey: evt.altKey,
      ctrlKey: evt.ctrlKey,
      metaKey: evt.metaKey,
      shiftKey: evt.shiftKey,
    }));
    void drainQueue();
  },
});
