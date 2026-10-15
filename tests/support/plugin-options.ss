;;; White-box cleanup of process-wide overrides used only by options tests.
prelude: :gerbil/core

(import :tuna/kernel :tuna/lib/plugin-options)
(export remove-plugin-option-override!)

(extern (option-overrides tuna/lib/plugin-options#option-overrides))

(def (remove-plugin-option-override! (p : plugin) (name : :symbol)) => :void
  (hash-put! option-overrides (plugin-name p)
             (filter (lambda (o) (not (eq? (car o) name)))
                     (hash-ref option-overrides (plugin-name p) []))))
