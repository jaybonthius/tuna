# Brief: align the kernel with Cordis

**Date:** 2026-10-14. **Status:** the seven decisions in "What changes" were approved by the owner on 2026-10-14; this brief needs approval as a whole, including the one decision below. Research: [`agents/research/cordis-alignment/README.md`](../../agents/research/cordis-alignment/README.md) (the full Cordis paper, arXiv 2608.25512, and its source).

## What this is and why

Tuna's plugin kernel follows Cordis, but in several places it drifted from Cordis without ever weighing the paper's reasons. The paper proves strong guarantees: turning a plugin off leaves things as if it never ran, and any sequence of changes ends where a clean start would. Those proofs rest on three rules Tuna broke: one provider per slot, plugins see only what they declared, and replacing a provider restarts what depends on it instead of migrating state. This work restores those rules, keeps Tuna's editor-specific additions with written reasons, and keeps every Emacs-style live facility (evaluating code, loading packages, rebinding keys) inside the same model.

## The picture

**Status:** planned.

![Swapping the layout plugin](../diagrams/swapping-a-plugin.svg)

Swapping, reloading, and restarting become one path: keep each plugin's saved data, turn the old things off (everything they added is undone), turn the new things on from a clean start, and give them the saved data back. That path already runs at every start-up, so it is tested every day.

## What changes

1. **Swap means restart plus restore.** The kernel's state handover and adapters go away. State that should survive is saved as plain data (the session store keeps it, even for plugins that are off) and restored into whatever plugin fills the slot next. In-memory state such as undo history is lost on a swap; you accepted that.
2. **One provider per slot.** Your `init.ss` declares which plugin fills each slot. Declaring two is an error that names both. Where several really make sense (file systems, language backends), one plugin owns the slot and others register with it.
3. **Plugins use only what they declared.** Using a service without listing it in `requires:` is an error naming both, as in Cordis. Interactive code (see below) is not restricted.
4. **Ties go by `init.ss` order,** not by which plugin happened to load last, so a reload ends exactly where a fresh start would.
5. **A command belongs to its plugin:** turning the plugin off cancels its running commands, including one waiting at a prompt.
6. **Start-up-only slots** (how keys are read, the browser connection) become configuration policy, enforced by reload, not by the kernel.
7. **Every place Tuna still differs from Cordis gets a recorded reason** in the ADRs: the editor thread and `C-g`, hooks in the kernel (ordered only by declared depth), contracts checked when a plugin turns on, and the "saved data outlives the plugin" rule.

## Emacs facilities stay first-class

`eval-buffer`, evaluating an expression, loading a package, rebinding a key, or running a command must work on the live editor, as in Emacs. They fit the model:
- **Every evaluation gets an owner,** like your `init.ss` code already does: a key bound or a hook added from `eval-buffer` is recorded as that buffer's, so it can be listed and undone.
- **Redefining a function** is plain redefinition (ADR 1), not a plugin change.
- **Loading a package** turns its plugins on through the same path as `init.ss`; **running a command** is `call-command`.
- **Interactive code is not restricted** by rule 3 (Cordis gives its root the same freedom).

## A walkthrough

1. **You replace the splits layout with a tabs layout in `init.ss` and reload.** The session store keeps the layout's saved data; the splits layout and everything using the layout turn off; the tabs layout turns on and receives the views, buffers, cursors and frame marks; your views appear as tabs. Your split sizes are gone (they were private to splits).
2. **Switching back to splits** restores splits' own saved arrangement, splits and all, because the session store kept it while splits was off.
3. **You remove the buffers plugin from `init.ss`, then add it back.** Turning it off saves its data (the open buffers, their text and points); turning it back on restores them. Undo history is lost.
4. **Your config has an error in a plugin.** During a reload, nothing changes: the running version stays on. At a cold start, that plugin stays off, and its saved data stays untouched on disk; fix the config, run `tuna reload`, and it comes back.
5. **You `eval-buffer` a file that binds `C-c x`.** The binding belongs to that evaluation. Evaluate the buffer again after editing it, and (see the decision) the old binding is replaced, not stacked.

## A code sample (package author's view)

```scheme
(defplugin (my-outline ctx)
  "Shows the layout as an outline."
  requires: [layout-service buffers-service]       ; using anything else is an error
  (context-add-session-slot! ctx 'my-outline
    save:    (lambda () (outline-state->data))      ; plain data only
    restore: (lambda (data) (data->outline-state! data)))
  ...)
```

Nothing else is needed to survive swaps, reloads and restarts. Names are illustrative.

## How it gets built

1. **Kernel:** one provider per slot; remove handover and adapters; declared-use checks with free interactive code; ties by declaration order; commands owned by their plugin. Tests that relied on outranking select their doubles in configuration instead.
2. **Restart plus restore:** reload and an explicit swap go through capture, turn off, turn on, restore; the layout and buffers contracts define a neutral saved form so a different plugin can restore another's data; start-up-only slots move to reload policy.
3. **Interactive evaluation owners:** `eval-buffer` and evaluating an expression run as owned units whose effects are recorded (the commands themselves can come with the REPL work).
4. **Record:** ADRs 2, 3, 4, 5, 11 and 12 amended with each kept difference and its reason.

The parked package-layout brief follows, rewritten on this foundation (one concept, one package owning its contract and default).

## Decision for you

**Evaluating a buffer again: replace or stack?**
- **Context:** in Emacs, re-evaluating a buffer that adds a hook or binds a key adds it again on top of the old one; removing a line from the buffer and re-evaluating leaves the old effect in place.
- **Options:** (a) as Emacs: effects accumulate; (b) each evaluation of a buffer replaces that buffer's previous effects (removed lines are undone), the same rule `reload-config` follows.
- **Recommendation: (b).** It is the Emacs behavior people wish they had, and it falls out of the model for free. Recorded as a divergence from Emacs.

## New terms

- **Provider:** the one plugin that fills a slot.
- **Restart:** turn a plugin off (everything it added is undone) and on again from a clean start.
- **Saved data:** plain data a plugin hands the session store, kept even while the plugin is off and restored when it, or a replacement, turns on.
