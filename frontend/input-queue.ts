// The one ordered queue of input items, shared by the keyboard and the
// pointer, so that "type, click, type" reaches the server in that order
// (ADR 7, ADR 10). Each item carries the tab's client id and the next
// sequence number; at most one POST is in flight.

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

export type Identity = Readonly<{ version: 1; clientId: string; sequence: number }>;

const client = loadClientId();
const queue: object[] = [];
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
          console.error("Tuna input was not accepted", response.status);
        }
      } catch (error) {
        console.error("Tuna input transport failed", error);
      } finally {
        // A failed response does not prove the command was not executed.
        queue.shift();
      }
    }
  } finally {
    draining = false;
  }
}

// Queue the item FACTS, with this tab's identity, and send it in turn.
export function enqueue<T extends object>(facts: T): void {
  const identity: Identity = { version: 1, clientId: client, sequence: nextSequence() };
  queue.push(Object.freeze({ ...identity, ...facts }));
  void drainQueue();
}
