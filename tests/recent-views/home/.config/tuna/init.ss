(import (tuna) (tuna plugins) (document) (web))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin recent-views
  (config
    (keys:bind! keys:global "s-o" recent-views:select-recent-view)))

(define client (web:add-client! 1))

(define (press! . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client client])
        (views:call-with-view (layout:selected-view) (lambda () (keys:press! client key)))))
    keys))

(define (atom view)
  (views:view (list (cons 'view (views:id view)) (cons 'buffer (buffers:name (views:buffer view))))))

(define (selected) (buffers:name (views:buffer (layout:selected-view))))

;; Lets the delay pass, so the selected view gets its tick.
(define (pause!) (sleep-for (* 2 (recent-views:delay))))
(import (console))
