#!/usr/bin/env gxi

(import :std/build-script)

;; The web transport embeds web/ at compile time.
(def web-assets
  (map (lambda (name) (path-expand name "web")) (directory-files "web")))

(defbuild-script
  `("tuna/version"
    "tuna/kernel/ids"
    "tuna/kernel/entries"
    "tuna/kernel/state"
    "tuna/kernel/plugins"
    "tuna/kernel/hooks"
    "tuna/kernel/loop"
    "tuna/kernel/slots"
    "tuna/kernel"
    "tuna/lib/timers"
    "tuna/lib/jobs"
    "tuna/services/keys"
    "tuna/services/text-store"
    "tuna/services/settings"
    "tuna/services/echo-area"
    "tuna/services/help"
    "tuna/services/buffers"
    "tuna/services/renderer"
    "tuna/services/minibuffer"
    "tuna/services/windows"
    "tuna/services/session"
    "tuna/plugins/keys"
    "tuna/plugins/rope"
    "tuna/plugins/string-text-store"
    "tuna/plugins/settings"
    "tuna/plugins/echo-area"
    "tuna/plugins/help-panel"
    "tuna/plugins/buffers"
    "tuna/plugins/session"
    "tuna/plugins/autosave"
    "tuna/plugins/single-window"
    "tuna/plugins/two-windows"
    "tuna/plugins/html-renderer"
    "tuna/plugins/plain-text-renderer"
    "tuna/prelude"
    "tuna/plugins/basic-editing"
    "tuna/plugins/minibuffer"
    "tuna/plugins/demo"
    "tuna/plugins/window-commands"
    "tuna/plugins/web/embed"
    (gxc: "tuna/plugins/web" (extra-inputs: ,web-assets))
    (exe: "tuna/main" bin: "tuna")))
