import { action } from "datastar";

type Keydown = Readonly<{
  version: 1;
  type: "keydown";
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
