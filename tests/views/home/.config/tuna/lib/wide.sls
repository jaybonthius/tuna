#!tuna
;; Sets a view's option on its own behalf, so unloading it takes the
;; value back.
(import (views))

(define (widen-view! view) (views:set-option! view views:drawn-screens 3))
