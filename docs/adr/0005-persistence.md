# 5. Persistence split by purpose, as plain Scheme data

Status: accepted (2026-10-11)

## Context

The owner wants state held in memory and periodically backed up to files of Scheme data. Emacs separates concerns: visited files, auto-save files for unsaved text, desktop/session files for open buffers and layout, `custom-file` for UI-edited settings, and `init.el` for code. The previous Gerbil attempt built one coherent atomic checkpoint of all registered models, which required versioned codecs for every model before anything could be saved.

## Decision

| What | Where | When | Owner |
|---|---|---|---|
| File contents | The visited file | Explicit save | Files plugin |
| Unsaved buffer text | `$XDG_STATE_HOME/tuna/autosave/` | Idle and on a timer | Autosave plugin |
| Session: open buffers, points, layout, histories | `$XDG_STATE_HOME/tuna/session.ss` | Idle and on exit | Each plugin's session slot |
| Settings changed from the UI | `$XDG_CONFIG_HOME/tuna/custom.ss` | On change | Customization plugin |
| User code | `$XDG_CONFIG_HOME/tuna/init.ss` | Edited by the user | User |

- **Session slots.** A plugin registers a slot through its context ([ADR 2](0002-plugins-contexts-and-services.md)) with a name, a schema version, a `save` procedure returning plain data, and a `restore` procedure accepting it. The session file maps slot names to versioned data. Unknown slots are preserved on rewrite, so disabling a plugin does not erase its data.
- **Format.** Data files are written with `write` and read with `read`, then validated. They are never evaluated. Only `init.ss` is code.
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
- **SQLite as the primary store** (an earlier Tuna plan). Rejected by the owner: rigid for tree-shaped, evolving state ([owner notes](../../research/owner-notes/layout.org)).
