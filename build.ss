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
    "tuna/kernel/jobs"
    "tuna/kernel/timers"
    "tuna/kernel"
    "tuna/services/keys"
    "tuna/services/renderer"
    "tuna/services/text-store"
    "tuna/services/settings"
    "tuna/services/echo-area"
    "tuna/services/help"
    "tuna/services/buffers"
    "tuna/services/minibuffer"
    "tuna/plugins/keys"
    "tuna/plugins/rope"
    "tuna/plugins/string-text-store"
    "tuna/plugins/settings"
    "tuna/plugins/echo-area"
    "tuna/plugins/help-panel"
    "tuna/plugins/buffers"
    "tuna/plugins/html-renderer"
    "tuna/prelude"
    "tuna/plugins/basic-editing"
    "tuna/plugins/minibuffer"
    "tuna/plugins/demo"
    "tuna/plugins/web/embed"
    (gxc: "tuna/plugins/web" (extra-inputs: ,web-assets))
    (exe: "tuna/main" bin: "tuna")))
