;;; The demo's delete-selection switch (C-c D in demo.ss): while this
;;; plugin is on, typing, deleting and yanking replace the active region.
prelude: :gerbil/core

(import :tuna/kernel
        :tuna/plugins/settings/contract
        :tuna/plugins/editing/contract)
(export delete-selection-demo)

(defplugin (delete-selection-demo ctx)
  "Typing, deleting and yanking replace the active region."
  requires: [settings-service editing-service]
  (context-set-setting! ctx delete-selection #t))
