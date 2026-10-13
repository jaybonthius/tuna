# 9. Settings and scoped values, with a thread-scoped dynamic layer

Status: accepted (2026-10-11), from the [capability audit](../research/capability-audit/README.md) (lanes 2, 3, 4). Replaces the settings bullet originally in ADR 4.

## Context

Emacs code constantly binds variables temporarily: `(let ((case-fold-search nil)) …)`, `(let ((inhibit-read-only t)) …)`, `(let ((default-directory root)) (compile …))`, `with-current-buffer`, `save-match-data`. Values also come from buffer-local bindings, directory-local and file-local variables, connection-local variables, and global defaults. Hooks and lists combine buffer-local and global values through the `t` marker. Emacs gives each buffer one local layer and keeps `let` bindings global to the single Lisp thread.

Tuna runs several suspended commands and tasks at once ([ADR 3](0003-command-loop-and-jobs.md)), so mutate-and-restore of shared values is unsound. Gerbil parameters are thread-scoped, inherited by child threads, and survive suspension because each task is its own thread.

## Decision

- **Settings** are declared with a name, a typed schema, a default, documentation, and an optional `safe` flag (`defcustom`). Plugins set values through their context, so values are owner-tagged and revert cleanly ([ADR 2](0002-plugins-contexts-and-services.md)).
- **Resolution order**, most specific first: the **dynamic layer** (thread-scoped bindings made with `with-settings`, the equivalent of Emacs `let` on special variables); view or window; the focused node and its ancestors; buffer; minor and major modes; project or directory; connection; frame or client; global. The chain is an ordered list that plugins can extend with new scopes.
- **Combiners.** Each setting declares how scopes combine: `shadow` (default; the most specific value wins), `append` or `prepend` (lists and hooks; replaces Emacs's `t` marker), or `merge`.
- **Command context in the dynamic layer.** `current-buffer`, match data, `inhibit-read-only`, `inhibit-quit`, `inhibit-modification-hooks`, and similar context are dynamic-layer values, so `with-current-buffer` and `save-match-data` are scoped bindings, never global writes.
- **Tasks and jobs.** Tasks inherit the dynamic layer of the code that started them. Jobs start with it cleared and receive any values they need as plain data ([ADR 3](0003-command-loop-and-jobs.md)).
- **Observability.** Settings have revisions and change notifications, so rendering, mode lines, and customization UIs react without ad hoc watchers.
- **Local values from files and directories** are accepted automatically when they validate against the setting's schema and the setting is marked safe. Anything that would run code requires an explicit trust decision.

## Consequences

- Ported `let`-bindings become `with-settings` forms with the same shape.
- Every lookup walks a short chain; caching per revision keeps this cheap.
- Settings without schemas cannot be safe; ported `defcustom` `:type` specifications can supply schemas.

## Alternatives considered

- **No temporary binding; explicit arguments everywhere.** Rejected: rewrites most ported code.
- **Mutate a shared value and restore it with `dynamic-wind`.** Rejected: suspended commands and tasks would observe each other's temporary values.
- **Emacs `safe-local-variable` predicates per setting.** Rejected in favor of schemas, which are needed anyway for customization and validation.

## Amendment: plugin options are not settings (2026-10-13, configuration stage 3)

`(use-plugin p key: value ...)` in `init.ss` gives a plugin **options** (`tuna/lib/plugin-options.ss`), declared by the plugin with `defplugin-options` (name, default, documentation, type). Options and settings are two concepts on purpose:

- **Options are per-declaration activation parameters.** They are checked when `init.ss` loads, with no service running (settings resolution is a startup-tier service that some plugins with options, such as the web transport, come up before), and a plugin reads them when it is turned on. Changing an option replaces that plugin on reload; there is no scope chain, no dynamic binding, and no change notification.
- **Settings are scoped runtime values,** resolved through the chain above while plugins run.
- **One type vocabulary.** When settings get schemas, they use the same `option-type` values and constructors (`string-type`, `boolean-type`, `symbol-type`, `integer-type`), not a second vocabulary; the type struct moves to a neutrally named library when `defsetting` first takes a type.
- **Editing.** The planned settings screen (configuration brief, decision 4) edits settings and saves them to `custom.ss`; options are edited only in `init.ss`, and are not a settings layer.

Recorded as a divergence in [`docs/emacs-equivalents.md`](../../docs/emacs-equivalents.md): Emacs has one mechanism, `defcustom` set through `use-package :custom` or customize.
