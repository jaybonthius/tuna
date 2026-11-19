(import (tuna) (tuna plugins) (web))
(use-plugin layout)
(on-unload (lambda () (display "configuration unloading") (newline)))

(define client (web:add-client! 1))

(define (press! key)
  (parameterize ([web:current-client client])
    (views:call-with-view (layout:selected-view) (lambda () (keys:press! client key)))))
(import (console))
