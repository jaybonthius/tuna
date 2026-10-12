# 5. Persistence split by purpose, as plain Scheme data

Status: accepted (2026-10-11); amended after the [capability audit](../research/capability-audit/README.md) (file-system service, encodings, reload).

## Context

The owner wants state held in memory and periodically backed up to files of Scheme data. Emacs separates concerns: visited files, auto-save files for unsaved text, desktop/session files for open buffers and layout, `custom-file` for UI-edited settings, and `init.el` for code. The previous Gerbil attempt built one coherent atomic checkpoint of all registered models, which required versioned codecs for every model before anything could be saved.

Emacs reaches remote and virtual files through `file-name-handler-alist` (TRAMP, compressed files) and preserves bytes that do not decode as raw-byte characters. Gambit rejects surrogate code points and invalid UTF-8, and has built-in codecs only for ASCII, ISO-8859-1, UTF-8, and UTF-16 ([lane 3](../research/capability-audit/03-runtime-and-environment.md)).

## Decision

| What | Where | When | Owner |
|---|---|---|---|
| File contents | The visited file | Explicit save | Files plugin |
| Unsaved buffer text | `$XDG_STATE_HOME/tuna/autosave/` | Idle and on a timer | Autosave plugin |
| Session: open buffers, points, layout, histories | `$XDG_STATE_HOME/tuna/session.ss` | Idle and on exit | Each plugin's session slot |
| Settings changed from the UI | `$XDG_CONFIG_HOME/tuna/custom.ss` | On change | Customization plugin |
| User code | `$XDG_CONFIG_HOME/tuna/init.ss` | Edited by the user | User |

- **File-system and process services.** Plugins access files and spawn processes only through the file-system and process services ([ADR 2](0002-plugins-contexts-and-services.md)), which pick a provider by path. The default provider is the local machine; remote (TRAMP-like) and archive providers can be added later without changing callers. `default-directory` is a scoped setting ([ADR 9](0009-settings-and-scoped-values.md)).
- **Encodings.** A visited text records its coding system, line-ending style, and byte-order mark. Bytes that do not decode are represented by reserved private-use code points and written back verbatim on save, so any file round-trips byte-for-byte. Encodings beyond Gambit's built-ins come from a `Coding` service.
- **Session slots.** A plugin registers a slot through its context (`context-add-session-slot!`) with a name, a schema version, a `save` procedure returning plain data, and a `restore` procedure accepting it. The session service's provider keeps the slots, not the kernel ([ADR 12](0012-kernel-boundary-and-replaceability.md)), so a plugin that registers a slot requires the session service; a configuration that keeps no session provides one that saves nothing. The session file maps slot names to versioned data. Unknown slots are preserved on rewrite, so disabling a plugin does not erase its data. Plugin reload uses the same slots ([ADR 2](0002-plugins-contexts-and-services.md)).
- **Format.** Data files are written with `write` and read with `read`, then validated. They are never evaluated. Only `init.ss` is code. Text properties are persisted only when their values are plain data.
- **Writes** go to a temporary file followed by an atomic rename. A corrupt file is moved aside and reported; Tuna starts without it rather than overwriting it.
- **Restore** happens after plugins activate, slot by slot. One slot failing does not prevent others.
- **SQLite** is available to plugins that need queries; it is not a core store.

## Consequences

- Saving does not require every subsystem to be versioned up front; each plugin opts in when it has state worth keeping.
- The session is not one atomic snapshot. Slots may be written at slightly different moments; restore must tolerate references to buffers that no longer exist.
- Autosave and session restore together cover crash recovery for unsaved text.

## Alternatives considered

- **One coherent checkpoint of the whole application (previous attempt).** Rejected: heavy codec machinery before there is anything to save, and one failure blocks all recovery.
- **Evaluating saved state as code (Emacs desktop files).** Rejected: data files must not execute.
- **SQLite as the primary store** (an earlier Tuna plan). Rejected by the owner: rigid for tree-shaped, evolving state ([owner notes](../research/owner-notes/layout.org)).
- **Direct OS file calls in plugins.** Rejected: remote files would later require touching every plugin.
