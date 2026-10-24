import { action } from "datastar";
import { send } from "./input-sender";

// The computer's clipboard, through the standard Clipboard API only. The
// page never inserts or keeps text itself: a paste goes to the server,
// which inserts it, and the server asks the page to copy.

type PasteFacts = Readonly<{ type: "paste"; text: string }>;

// Why a copy did not reach the clipboard: the page has no
// navigator.clipboard (browsers give it only to HTTPS and localhost
// pages), or writeText rejected, with the error's name.
type ClipboardReport = Readonly<{
  type: "clipboard";
  outcome: "unavailable" | "refused";
  reason?: string;
}>;

// The page shell's document paste listener: the browser's paste key
// (pasteChord in tuna-keyboard.ts) fires it, with the clipboard's text.
action({
  name: "tunaPaste",
  apply({ evt }: { evt?: Event }): void {
    if (evt?.type !== "paste") return;
    evt.preventDefault();
    const text = (evt as ClipboardEvent).clipboardData?.getData("text/plain") ?? "";
    if (text !== "") send<PasteFacts>({ type: "paste", text });
  },
});

// The server's one-time copy instruction, an element appended to the body
// after a screen, holding the text as a JSON string: copy it, then remove
// the element.
action({
  name: "tunaCopy",
  apply({ el }: { el: HTMLElement }): void {
    const text = JSON.parse(el.textContent ?? "\"\"") as string;
    el.remove();
    const clipboard = navigator.clipboard;
    if (clipboard === undefined) {
      send<ClipboardReport>({ type: "clipboard", outcome: "unavailable" });
      return;
    }
    clipboard.writeText(text).catch((error: unknown) => {
      const name = (error as { name?: unknown } | null)?.name;
      const reason = typeof name === "string" && /^[A-Za-z]{1,64}$/.test(name) ? name : "Error";
      send<ClipboardReport>({ type: "clipboard", outcome: "refused", reason });
    });
  },
});
