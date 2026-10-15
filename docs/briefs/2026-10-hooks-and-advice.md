# Brief: hooks and advice

**Date:** 2026-10-15. **Status:** proposed. Roadmap item 4 of "getting the core back to its intended shape". Research: [`agents/research/hooks-advice/`](../../agents/research/hooks-advice/) ([Emacs](../../agents/research/hooks-advice/emacs.md), [other systems](../../agents/research/hooks-advice/prior-art.md), [Gerbil and Tuna's hooks](../../agents/research/hooks-advice/gerbil-and-tuna.md)). Changes [ADR 1](../../agents/adr/0001-language-and-extension-surface.md) and [ADR 2](../../agents/adr/0002-plugins-contexts-and-services.md).

## What we're building and why

Tuna gives plugins three ways to change other code's behavior while it runs:

- **Hooks** (built): code announces "this happened", and plugins add callbacks.
- **Advice** (not built): a plugin wraps an existing command or function so that its own code runs before, after or around it. Emacs packages use this widely, and the profiler needs it to time a function without editing its source.
- **Redefinition** (partly built): replacing a function's definition while Tuna runs, as `C-M-x` does in Emacs.

The research found three things that shape the design:

1. **The best-known lesson is to prefer declared extension points to wrapping.** Emacs's manual tells packages to use hooks and to treat advice as a last resort. The authors of Clojure's advice library now tell people not to use it, because it "created more problems than it solved". Every newer design adds the same two things: each wrapper has an owner that removes it, and you can list who wraps what. Tuna's hooks already have owners; advice will have both.
2. **Idiomatic Gerbil cannot advise or redefine an arbitrary package function one at a time.** ADR 1 assumed that a package function could be replaced from outside with `set!`. That works only for untyped functions. Gerbil compiles calls to a *typed* function (and our conventions type everything) straight to the original, so callers never see a replacement. The only ways around this use undocumented compiler internals, which are hacks. Separately, evaluating `(def (f …))` interactively today creates a new `f` in the session and leaves the package's `f` untouched.
3. **Tuna's hooks are sound.** Owner-based removal, "the same name replaces" and the error policy all hold up against Emacs and the other systems. Three small fixes are below.

So advice and one-at-a-time redefinition work on things made for them: **commands, service methods, and functions a package declares advisable.** Anything else changes when its package is reloaded (roadmap "Later" item 6). That matches Emacs's own advice to package authors: ask the owner for an extension point.

## The pictures

![What can be advised, and who keeps the advice](../diagrams/advice-targets.svg)

![Pressing Backspace with an advised command](../diagrams/advice-backspace.svg)

**Status:** planned. Today nothing can be advised; commands and services exist, and declared functions do not.

## A walkthrough: a "hungry delete" plugin

1. Your `init.ss` turns on `hungry-delete`. When it starts, the plugin adds **advice** named `hungry`, of the **around** kind, to the command `delete-backward-char`, which belongs to `basic-editing`.
2. The commands plugin records the advice with its owner, name, kind and depth, and builds the combined command once. Commands with no advice run exactly as they do today.
3. You press Backspace. The key handling plugin runs `delete-backward-char`, and the commands plugin calls the combined command.
4. The `hungry` advice runs first. If there are spaces before point, it deletes them all and stops (4a). Otherwise it calls the original command (4b).
5. `M-x describe-advice` on `delete-backward-char` lists the advice in calling order: `hungry`, around, from `hungry-delete`, with the place in its source where it was defined.
6. You change `delete-backward-char` and evaluate it again. The original is replaced *under* the advice, and Backspace is still hungry.
7. You turn `hungry-delete` off. Its clean-up removes the advice, and Backspace runs the newest `delete-backward-char` directly.

## What a package author writes

The names are provisional.

```scheme
;; A plugin advising another plugin's command.
(defplugin (hungry-delete ctx)
  "Backspace deletes all the spaces before point at once."
  requires: [commands-service]
  (advise-command! ctx 'delete-backward-char 'hungry
    around: (lambda (original)
              (if (spaces-before-point?)
                (delete-spaces-before-point!)
                (original)))))

;; A package that wants a function to be advisable and redefinable declares it.
;; Callers anywhere see the newest definition and any advice.
(defadvisable (indent-column (line : :fixnum)) => :fixnum
  (current-indentation line))

;; Another plugin rounds that function's answer to multiples of 4.
(advise! ctx indent-column 'round-to-four
  filter-return: (lambda ((column : :fixnum)) (fx* 4 (fxquotient column 4))))
```

## The rules

**Advice.**
- Each piece of advice has an owner (a plugin, or your session for code you evaluate), a name, a kind and a depth. Adding advice with the same owner and name replaces it. Turning the owner off removes it.
- **Kinds:** ADR 1's ten Emacs kinds (`before`, `after`, `around`, `override`, `filter-args`, `filter-return`, and the four `before-while`-style variants). Each is a few lines over one way of combining. Emacs's newer eleventh kind, which changes only how a command reads its arguments, isn't needed: Tuna commands read their arguments inside their body.
- **Order:** lower depth is outermost. Equal depths go by the owners' order in `init.ss`, not by when the advice was added, so a reload can't reorder them.
- **Errors:** an error inside advice propagates like an error in the function itself, and the report names the advice and its owner. Hooks are different: a failing callback is removed and the rest continue. Silently skipping advice would change what the function returns.
- **Visible:** `describe-advice` lists everything wrapping a command or function. This is the improvement over Emacs that the research recommends most.
- **Cost:** advice is combined when it changes, not on every call. Unadvised commands and service methods cost nothing extra. A declared function costs about 3 nanoseconds more per call even without advice (measured), so packages declare only the functions others need to change. One forwarding piece of advice adds 1–5 nanoseconds.
- **Not advisable:** hooks (adding a callback at a chosen depth already does before or after), Tuna's kernel (ADR 1), and patterns like "every function matching `foo-*`". The profiler's "profile this plugin" will add a listed set of individual advice instead.

**Redefinition.** Evaluating a command or a declared function again replaces its definition in place, keeping its advice. Hook callbacks already call the current definition of a named function. Any other function changes when its package is reloaded.

**Where it lives.** The way advice is combined is a small library outside the kernel. Commands keep their own advice in the commands plugin. Service methods need the only kernel change: alongside each service's provider, the kernel keeps an "advised view" of it and hands that out while advice exists. Advice never counts as a new provider, so it doesn't restart anything.

**Hooks: three fixes, nothing new.**
- A callback removed for failing leaves its clean-up note behind. This is the same leak shape as the one just fixed. Remove the note with the callback.
- Equal-depth callbacks run in registration order, so a reload can reorder them (a `TODO.md` item). Order them by their owners' place in `init.ss`, as entries and advice are ordered.
- Correct `docs/emacs-equivalents.md`. Ordinary Emacs hooks stop at a failing function and keep it; only `pre-command-hook` and `post-command-hook` remove it, which Tuna does for every hook. Also record this and the ordering as deliberate divergences.
- **Not added until a plugin needs them:** hooks that stop at the first answer (Emacs's `run-hook-with-args-until-success`) and per-buffer hooks. The profiler will need a way to time each callback; that comes with the profiler.

## Decisions for you

1. **Which package functions can be advised and redefined one at a time?** This narrows ADR 1, which said "any exported function of a package".
   - (a) **Commands, service methods, and functions their package declares with `defadvisable`;** everything else changes by reloading its package. *Recommended:* it's plain Gerbil (a macro and a record), costs only what is declared, and follows the lesson every system above learned.
   - (b) Every package function, by having Tuna's package prelude turn every `def` into a declared function. That adds about 3 nanoseconds to every package call. It's essentially what the previous attempt did, and ADR 1 rejected that for a measured 9% slowdown.
   - (c) Leave out the type signatures on functions that should be redefinable, so `set!` reaches their callers. It conflicts with our typing convention, and it fails silently: a typed function quietly ignores the redefinition.

## New terms

- **Advice:** code wrapped around a command or function, owned by a plugin.
- **Advice kind:** when the advice runs relative to the original, for example `before`, `around` or `filter-return`.
- **Declared (advisable) function:** a package function defined with `defadvisable`, so other code can advise it and evaluation can redefine it.
- **Depth:** a number placing advice or a hook callback; lower means outermost or earlier.
