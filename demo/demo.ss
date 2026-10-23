;;; The demo plugin, for development only (`tuna --config demo/init.ss`):
;;; swapping the text store (C-c s), basic editing (C-c p), hungry
;;; delete (C-c h), the terminal theme (C-c T) and the delete-selection
;;; setting (C-c D) while Tuna runs, and
;;; waiting off the editor thread (C-c W, which C-g quits). The
;;; demo's other commands (the *welcome* tree buffer, endless loops,
;;; describe-services, renaming, renderer and layout swaps, the slow
;;; digit highlighter) are test fixtures from tuna/test-support/ that
;;; demo/init.ss declares beside it. The demo turns other plugins on
;;; and off, so it imports them; ordinary plugins do not. Nothing in tuna/
;;; or starter/ may import it (tuna/kernel/boundary-test.ss).
prelude: :gerbil/core

(import :tuna/plugins/commands/contract
        :tuna/kernel
        :tuna/plugins/keys/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/region/contract
        :tuna/configuration
        :tuna/lib/background
        :tuna/plugins/text-store/plugin
        :tuna/plugins/basic-editing/plugin
        :tuna/plugins/hungry-delete/plugin
        "../plugins/text-store/tests/support/string-text-store"
        "../tests/support/theme-terminal")
(export demo)

(def (toggle-plugin! (p : plugin)) => :void
  (if (plugin-active? p)
    (deactivate-plugin! p)
    (activate-plugin! p)))

;; Sleep SECONDS, then return them: work for off-thread, on its thread.
(def (slow-answer (seconds : :real)) => :real
  (thread-sleep! seconds)
  seconds)

;; Turns delete-selection on while it is on itself.
(defplugin (delete-selection-demo ctx)
  "Typing, deleting and yanking replace the active region."
  requires: [settings-service]
  (context-set-setting! ctx delete-selection #t))

(defplugin (demo ctx)
  "Demo commands: swap text store (C-c s), toggle basic editing (C-c p), hungry delete (C-c h), the terminal theme (C-c T), delete-selection (C-c D) and waiting off the editor thread (C-c W)."
  requires: [commands-service input-service configuration-service]
  optional: [settings-service region-service] ; delete-selection-demo sets region's setting
  (define-command ctx (swap-text-store) "Switch between the rope and the plain-string text store."
    (if (plugin-active? string-text-store)
      (swap-plugins string-text-store rope-text-store)
      (swap-plugins rope-text-store string-text-store))
    (message (if (plugin-active? string-text-store)
               "Text store: plain strings"
               "Text store: rope")))
  (define-command ctx (toggle-basic-editing) "Turn the basic-editing plugin off or on."
    (toggle-plugin! basic-editing)
    (message (if (plugin-active? basic-editing) "Basic editing on" "Basic editing off")))
  (define-command ctx (toggle-hungry-delete) "Turn the hungry-delete plugin off or on."
    (toggle-plugin! hungry-delete)
    (message (if (plugin-active? hungry-delete) "Hungry delete on" "Hungry delete off")))
  (define-command ctx (toggle-theme-terminal) "Turn the terminal theme (theme-terminal) off or on."
    (toggle-plugin! theme-terminal)
    (message (if (plugin-active? theme-terminal) "Terminal theme on" "Terminal theme off")))
  (define-command ctx (toggle-delete-selection) "Turn the delete-selection setting on or off."
    (toggle-plugin! delete-selection-demo)
    (message (if (plugin-active? delete-selection-demo) "Delete selection on" "Delete selection off")))
  (define-command ctx (wait-demo) "Wait three seconds off the editor thread, then say so; C-g quits the wait."
    (message "Waiting three seconds off the editor thread; C-g quits")
    (message (string-append "Waited " (number->string (off-thread slow-answer 3)) " seconds off the editor thread")))
  (keymap-set ctx "C-c W" 'wait-demo)
  (keymap-set ctx "C-c h" 'toggle-hungry-delete)
  (keymap-set ctx "C-c T" 'toggle-theme-terminal)
  (keymap-set ctx "C-c D" 'toggle-delete-selection)
  (keymap-set ctx "C-c p" 'toggle-basic-editing)
  (keymap-set ctx "C-c s" 'swap-text-store))
