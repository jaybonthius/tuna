prelude: :gerbil/core

(import :tuna/version)
(export main)

(def (main . args)
  (displayln "Tuna " (tuna-version)))
