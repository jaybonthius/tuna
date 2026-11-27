(import (hooks) (options) (tables) (timers) (plugins))
(import (tuna))

;; Chez judges an object stale by file times, which the file system keeps
;; to its clock tick, so a source written in the tick its object was
;; compiled in would count as compiled.
(define (put-version! version path)
  (timers:sleep 0.01)
  (let ([home (getenv "HOME")])
    (with-output-to-file (string-append home "/" path)
      (lambda ()
        (put-string (current-output-port)
          (call-with-input-file (string-append home "/versions/" version) get-string-all)))
      'replace)))
(import (console))
