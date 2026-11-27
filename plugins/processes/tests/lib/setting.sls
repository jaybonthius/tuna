#!tuna
(import (options))

;; An option such as processes:log-size reaches the threads that read
;; output only when set, never through options:with's binding on one
;; thread; and a task's winders run at each of its pauses, so no
;; dynamic-wind can hold the setting while the thunk waits.
(define (with option value thunk)
  (options:set! option value)
  (thunk)
  (options:unset! option))
