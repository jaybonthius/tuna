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
    "tuna/kernel/tasks"
    "tuna/kernel/plugins"
    "tuna/kernel/hooks"
    "tuna/kernel/loop"
    "tuna/kernel"
    "tuna/lib/timers"
    "tuna/lib/jobs"
    "tuna/lib/plugin-options"
    "tuna/lib/configuration"
    "tuna/services/commands"
    "tuna/services/keys"
    "tuna/services/text-store"
    "tuna/services/settings"
    "tuna/services/help"
    "tuna/services/buffers"
    "tuna/services/echo-area"
    "tuna/services/renderer"
    "tuna/services/minibuffer"
    "tuna/services/session"
    "tuna/services/layout"
    "tuna/services/buttons"
    "tuna/services/configuration"
    "tuna/plugins/commands"
    "tuna/plugins/keys"
    "tuna/plugins/rope"
    "tuna/plugins/settings"
    "tuna/plugins/echo-area"
    "tuna/plugins/help-buffer"
    "tuna/plugins/buffers"
    "tuna/plugins/session"
    "tuna/plugins/autosave"
    "tuna/plugins/layout/tree"
    "tuna/plugins/layout"
    "tuna/plugins/html-renderer"
    "tuna/plugins/buttons"
    "tuna/prelude"
    "tuna/config"
    "tuna/plugins/basic-editing"
    "tuna/plugins/minibuffer"
    "tuna/plugins/view-commands"
    "tuna/config-blocks"
    "tuna/plugins/web/embed"
    (gxc: "tuna/plugins/web" (extra-inputs: ,web-assets))
    ;; tuna init writes the starter configuration, which boot embeds.
    (gxc: "tuna/boot" (extra-inputs: ("starter/init.ss")))
    "tuna/control"
    "tuna/plugins/reload-config"
    (exe: "tuna/main" bin: "tuna")))
