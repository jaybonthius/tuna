;;; The demo plugin, for development only (`tuna --config demo/init.ss`):
;;; swapping the text store (C-c s) and basic editing (C-c p) while Tuna
;;; runs. The demo's other commands (the *welcome* tree buffer, endless
;;; loops, describe-services, renaming, renderer and layout swaps,
;;; the slow digit highlighter) are test fixtures from tuna/test-support/
;;; that demo/init.ss declares beside it. The demo turns other plugins on
;;; and off, so it imports them; ordinary plugins do not. Nothing in tuna/
;;; or starter/ may import it (tuna/kernel/boundary-test.ss).
prelude: :gerbil/core

(import :tuna/plugins/commands/contract
        :tuna/kernel
        :tuna/plugins/keys/contract
        :tuna/configuration
        :tuna/plugins/text-store/plugin
        :tuna/plugins/basic-editing/plugin
        "../plugins/text-store/tests/support/string-text-store")
(export demo)

(def (toggle-plugin! (p : plugin)) => :void
  (if (plugin-active? p)
    (deactivate-plugin! p)
    (activate-plugin! p)))

(defplugin (demo ctx)
  "Demo commands: swap the text store (C-c s) and basic editing (C-c p) while Tuna runs."
  requires: [commands-service input-service configuration-service]
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
  (keymap-set ctx "C-c p" 'toggle-basic-editing)
  (keymap-set ctx "C-c s" 'swap-text-store))
