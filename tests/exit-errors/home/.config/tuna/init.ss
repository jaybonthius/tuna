(import (tuna) (tuna plugins) (document) (web) (ask))
(use-plugin layout)
(use-plugin minibuffer)
(use-plugin exit-errors)
(on-unload (lambda () (display "configuration unloading") (newline)))

(define client (web:add-client! 1))

(define (press! key)
  (parameterize ([web:current-client client])
    (views:call-with-view (layout:selected-view) (lambda () (keys:press! client key)))))

(define (prompts)
  (document:datums (buffers:document (buffers:find " *Minibuf*"))))
(import (console))
