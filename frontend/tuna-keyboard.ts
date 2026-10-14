import { action } from "datastar";
import { enqueue } from "./input-queue";

type KeydownFacts = Readonly<{
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

action({
  name: "tunaKeyboard",
  apply({ evt }: { evt?: Event }): void {
    if (!(evt instanceof KeyboardEvent) || evt.type !== "keydown") return;
    if (!evt.isComposing) evt.preventDefault();
    enqueue<KeydownFacts>({
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
    });
  },
});
