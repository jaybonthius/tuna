import { action, getPath } from "datastar";
import { sentItems } from "./input-sender";

// Each screen's data-init confirms it applied (tunaApplied), which lets
// the server send the next (ADR 7), with what the page measured of it on
// its own clock. The server joins these durations to its own by ids (the
// screen's stream, count and revision, each input's sequence), never by
// comparing clocks:
//   morph   from the screen's event arriving to it being applied;
//   settle  from then until its data-init ran;
//   keys    for each input of this page the screen is the first to include
//           (its data-through), from the input's event to its post, and
//           from its post to this screen arriving;
//   painted earlier screens' times from applied to the first task after
//           the next animation frame, which follows their paint (as VS
//           Code measures input latency), each [stream, count, ms]. They go
//           with the next confirmation, or alone when none follows within
//           paintReportDelay.

type Arrival = { arrived: number; applied: number };

// The newest screens' arrivals, by revision.
const arrivals = new Map<number, Arrival>();
const arrivalsLimit = 16;
const paintReportDelay = 200;

const painted: [number, number, number][] = [];
const paintedLimit = 16;
let paintTimer: ReturnType<typeof setTimeout> | null = null;

type PatchDetail = { type?: string; argsRaw?: { elements?: unknown } };

// The revision a screen's event carries on its root element, or null.
function eventRevision(evt: Event): number | null {
  const detail = (evt as CustomEvent<PatchDetail>).detail;
  if (detail?.type !== "datastar-patch-elements") return null;
  const elements = detail.argsRaw?.elements;
  if (typeof elements !== "string") return null;
  const found = /^<[^>]*?\sdata-revision="(\d+)"/.exec(elements.slice(0, 2048));
  return found ? Number(found[1]) : null;
}

// Before Datastar applies an event (capturing on window), and after it
// has (Datastar's own listener on document was added first).
window.addEventListener("datastar-fetch", (evt: Event) => {
  const revision = eventRevision(evt);
  if (revision === null) return;
  const now = performance.now();
  arrivals.set(revision, { arrived: now, applied: now });
  if (arrivals.size > arrivalsLimit) arrivals.delete(arrivals.keys().next().value as number);
}, true);
document.addEventListener("datastar-fetch", (evt: Event) => {
  const revision = eventRevision(evt);
  const arrival = revision === null ? undefined : arrivals.get(revision);
  if (arrival) arrival.applied = performance.now();
});

function post(path: string, applied: object): void {
  void fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Datastar-Request": "true" },
    body: JSON.stringify({ tab: getPath("tab"), applied }),
  }).catch(() => {});
}

function takePainted(): [number, number, number][] {
  const taken = painted.splice(0);
  if (paintTimer !== null) { clearTimeout(paintTimer); paintTimer = null; }
  return taken;
}

action({
  name: "tunaApplied",
  apply({ el }: { el: Element }, path: string): void {
    const now = performance.now();
    const revision = Number(el.getAttribute("data-revision"));
    const through = Number(el.getAttribute("data-through") ?? 0);
    const arrival = arrivals.get(revision);
    const arrived = arrival?.arrived ?? now;
    const keys: [number, number | null, number][] = [];
    for (const [sequence, item] of sentItems) {
      if (sequence > through) continue;
      keys.push([sequence, item.event === null ? null : item.sent - item.event, arrived - item.sent]);
      sentItems.delete(sequence);
    }
    const query = new URLSearchParams(path.slice(path.indexOf("?") + 1));
    const stream = Number(query.get("stream"));
    const count = Number(query.get("count"));
    post(path, {
      revision, through, keys,
      ...(arrival ? { morph: arrival.applied - arrival.arrived, settle: now - arrival.applied } : {}),
      ...(painted.length > 0 ? { painted: takePainted() } : {}),
    });
    requestAnimationFrame(() => setTimeout(() => {
      painted.push([stream, count, performance.now() - now]);
      if (painted.length > paintedLimit) painted.shift();
      if (paintTimer === null) {
        paintTimer = setTimeout(() => {
          paintTimer = null;
          const report = takePainted();
          if (report.length > 0) post(path, { painted: report });
        }, paintReportDelay);
      }
    }, 0));
  },
});
