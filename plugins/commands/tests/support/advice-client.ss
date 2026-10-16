;;; Also compiled separately to prove routing across module boundaries.
prelude: :gerbil/core
(import :tuna/kernel :tuna/plugins/commands/contract
        (only-in :tuna/prelude advise! unadvise! advice-for))
(export install-client-advice! remove-client-advice! client-advice replace-client-callback!)
(declare (separate))

(def callback (lambda () 'initial))
(def (replace-client-callback! (replacement : :procedure)) => :void
  (set! callback replacement))

(def (install-client-advice! (ctx : context)) => :void
  (let ((add #f) (remove #f) (inspect #f))
    (advise! ctx (command action) 'client override: callback)))
(def (remove-client-advice! (ctx : context)) => :void
  (let ((add #f) (remove #f) (inspect #f))
    (unadvise! ctx (command action) 'client)))
(def (client-advice) => :t
  (let ((add #f) (remove #f) (inspect #f))
    (advice-for (command action))))
