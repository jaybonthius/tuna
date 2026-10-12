# Shared brief: Tuna kernel-contract research

You are one of three parallel **read-only** research lanes. Do not edit, create, or delete any file except the single output file bound for you. Do not modify `/home/jay/Code/workbench-gerbil/tuna` or any other repository. Do not run Git commands that change anything. You may clone public repositories into `/tmp` for reading.

## Situation

Tuna (`/home/jay/Code/workbench-gerbil/tuna`) is an Emacs-like computing environment in Gerbil Scheme, rendered in the browser. The owner's central direction: **almost everything is a plugin; the kernel is nearly nothing but the scaffolding that makes plugins possible**, in the spirit of Cordis (https://github.com/cordiverse/cordis). Read first:

- `agents/adr/0012-kernel-boundary-and-replaceability.md`, `0002-plugins-contexts-and-services.md`, `0003-command-loop-and-jobs.md`, `0008-input-keymaps-and-command-composition.md`, `0007-rendering-and-transport.md` (and skim the others).
- `agents/research/kernel-audit-2026-10-12.md`: an independent audit that found the kernel drifting (hooks, timers, session slots, a browser keyboard event type, text-range logic in jobs, per-feature kernel fields) and the buffers "contract" actually being the implementation.
- The current kernel source: `tuna/kernel/*.ss`, `tuna/kernel.ss`.

We are about to write a **kernel contract**: the exact list of what the kernel contains and exports, what it must never know about, and a line budget, so drift becomes visible. Your lane supplies evidence for it.

## Rules for your report

- Cite sources (file:line, URL, manual node). Distinguish fact from inference.
- Be concrete and skeptical; prefer the smallest kernel that works. Say when something should *not* be in the kernel.
- Under about 8,000 words. End with a short "Recommendations for Tuna's kernel contract" list.
