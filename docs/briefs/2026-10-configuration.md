# Brief: your configuration, reloading it, and recovering from mistakes

**Status:** proposed, awaiting your decisions below. Nothing is built yet.

## What this is and why

Today Tuna turns on a fixed list of 15 plugins written into its start-up code. You cannot choose them, and there is no `init.ss`. This brief proposes how you choose your plugins, write your own code, reload both without restarting, and recover when something you wrote is broken.

Three rules shape it:
- **There is no standard setup.** Tuna ships a starter configuration as a file you copy and own, but nothing ever falls back to it or to any built-in plugin set.
- **No stored history.** Tuna never keeps old copies of your configuration. When a reload goes wrong, the running editor is the "last good" version: anything that fails is undone and the old part keeps running.
- **The kernel does not change.** Loading a configuration only needs "turn this plugin on" and "turn it off", which the kernel already has.

Evidence: [what Gerbil can do](../../agents/research/configuration/01-gerbil-runtime.md) (tested) and [how other systems do it](../../agents/research/configuration/02-prior-art.md): Cordis and Koishi (Tuna's plugin model), Caddy and nginx (check a new config, keep the old one running if it fails), Kubernetes and systemd (one failing part never takes the others down), Helix, Neovim, Doom Emacs, Lem, Nyxt.

## The picture

Starting up:

![What happens when Tuna starts](../diagrams/config-startup.svg)

Reloading:

![What happens when you reload](../diagrams/config-reload.svg)

## Your files

Two files in `~/.config/tuna/`:
- **`plugins.ss`, the plugin list.** Which plugins to use and with what options. It is plain data: Tuna reads it but never runs it, so a typo can't hang or crash anything, and Tuna can check it before using it. It is also where you choose the parts that can only be picked at start-up, such as how keys work.
- **`init.ss`, your code.** Key bindings, hooks, small commands, even whole plugins of your own. It is itself a plugin, turned on after everything else, so reloading it first undoes everything its previous version added.

Settings you change through Tuna's own interface go to `custom.ss`, as already decided.

```scheme
;; ~/.config/tuna/plugins.ss: which plugins, with what options. Read, never run.
((keys        :tuna/plugins/keys)
 (browser     :tuna/plugins/web       port: 8001)
 (buffers     :tuna/plugins/buffers)
 (text-store  :tuna/plugins/rope)
 (windows     :tuna/plugins/two-windows)
 (modal       :jay/modal              leader: "SPC")   ; a package you installed
 (demo        :tuna/plugins/demo      disabled: #t))
```

```scheme
;; ~/.config/tuna/init.ss: your own code, turned on last.
#lang :tuna/prelude
(keymap-set "C-c t" 'toggle-theme)
(defcommand (insert-date) "Insert today's date."
  (insert (todays-date)))
```

Names and syntax are illustrative; they will settle as this is built.

## A walkthrough

1. **You add a plugin with a typo in an option** (`leader: SPC` without quotes) and run `reload-config`. The check step finds it before anything changes: "plugins.ss line 6: modal option leader must be a string". Tuna keeps running exactly as before.
2. **You fix it and reload.** Tuna compares the list with what is running. Only `modal` is new, so only `modal` is turned on; nothing else is touched.
3. **Your new `init.ss` has a bug** that raises an error halfway through. That version is undone completely, nothing half-applied, and the previous `init.ss` you were running is turned back on. The message names the line.
4. **Next morning you break `modal`, your own input plugin, and restart Tuna.** At start-up there is no running editor to keep, so Tuna turns on every plugin it can, skips `modal` and the two plugins that need it, and stays running. Since you can't type into Tuna, the report goes to the terminal you started it from: "modal failed: modal.ss line 42 ... skipped: 2 plugins that need it". You fix the file in any editor and run `tuna reload` in that terminal. Tuna reloads as in step 2, and `modal` comes up.
5. **Before restarting next time,** you can run `tuna check`, which does all of the start-up checks without starting anything and lists every problem.

## What gets built first

- The start-up step reads `plugins.ss` instead of the hard-coded list.
- A starter configuration ships with Tuna.
- `init.ss` is loaded as your own plugin.
- Reload works from inside Tuna (`reload-config`) and from a terminal (`tuna reload`).
- `tuna check` runs the start-up checks without starting anything.
- A report says what worked, what failed and why, and what was skipped because something it needed failed.

Later, each with its own short plan: narrowing a broken configuration down to the bad part by switching halves off (VS Code's "extension bisect", kept only in memory), reloading the code of plugins themselves while Tuna runs, and installing packages from inside Tuna.

Things to know:
- **Running your code needs part of Gerbil built into Tuna:** the expander, which turns code like `def` and `import` into something runnable. It adds about 1.7 MB and about 80 ms the first time it's used, and can load in the background.
- **Reloading Tuna's own compiled plugins in place does not work in Gerbil;** reloading from source does. That shapes the later plugin-reload work, not this one.
- **Nothing in the kernel changes.** The start-up step lives outside it, and the reload and check commands live in an ordinary configuration plugin you could replace.

## Decisions for you

1. **Two files: a plugin list as data, plus `init.ss` as code.**
   - *Options:* (a) two files as above; (b) one `init.ss` that also chooses plugins in code.
   - *Recommendation:* (a). Start-up parts must be chosen before any of your code runs (Emacs needed `early-init.el` for the same reason). A data list can be checked before use, can't hang start-up, and Tuna can switch entries on and off for you.
2. **First run with no configuration.**
   - *Options:* (a) Tuna copies the starter files into `~/.config/tuna/` once and tells you; (b) Tuna starts nothing and tells you to run `tuna init`.
   - *Recommendation:* (a). After the copy the files are yours; Tuna never touches them again.
3. **Where the start-up report goes when you can't see Tuna.**
   - *Options:* (a) the terminal only; (b) the terminal, and also a log file in Tuna's state folder that is replaced on every start; (c) also a recovery page in the starter configuration, as an ordinary plugin with its own address, so a broken input plugin can't take it down.
   - *Recommendation:* (b). The log matters when Tuna is started without a terminal, by a desktop launcher or a service. It is a report, not remembered configuration: nothing ever reads it back. (c) can come later if you want it.
4. **When `init.ss` and the settings interface set the same thing, which wins?**
   - *Options:* (a) your code wins, and help shows "set by init.ss line 12, overriding a setting you saved"; (b) the interface wins.
   - *Recommendation:* (a). Code you wrote is the more deliberate choice, and help makes the override visible instead of mysterious.

## New terms

- **Plugin list:** `plugins.ss`, the data file saying which plugins to use and with what options.
- **Starter configuration:** the files Tuna ships for you to copy and change; never a fallback.
- **Reload:** check your files, compare them with what's running, and change only what differs; anything that fails is undone and the old version keeps running.
- **Start-up report:** what came up, what failed and why, and what was skipped because something it needed failed.
