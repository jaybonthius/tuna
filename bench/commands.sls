#!tuna
(import (commands) (bench filler) (hooks))

(define (now-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (median xs)
  (list-ref (list-sort < xs) (quotient (length xs) 2)))

(define batch 2000)

(define (ns-per-op thunk)
  (median
    (map (lambda (k)
           (collect-rendezvous)
           (let ([start (now-ns)])
             (do ([i 0 (fx+ i 1)]) ((fx= i batch)) (thunk))
             (/ (- (now-ns) start) (exact->inexact batch))))
         (iota 9))))

(define (bytes-per-op thunk)
  (let ([before (bytes-allocated)])
    (do ([i 0 (fx+ i 1)]) ((fx= i batch)) (thunk))
    (/ (- (bytes-allocated) before) (exact->inexact batch))))

(define (show name value)
  (printf "~a ~,2f\n" name value))

(define %seen 0)

(commands:define-command (nothing) "Does nothing." #f)

(commands:define-command (counted [n (commands:prefix-number)])
  "Takes the prefix number."
  n)

(commands:define-command (nested) "Runs nothing inside." (commands:run nothing))

(define (keystroke) (commands:run counted))

;; (bench filler) fills the registry, as every plugin of an editor
;; would. The hooks get entries, as an undo, a display and a log would
;; add.
(define (fill!)
  (do ([i 0 (fx+ i 1)]) ((fx= i 3))
    (hooks:add! commands:before-command (lambda (c) (set! %seen (fx+ %seen 1))))
    (hooks:add! commands:after-command (lambda (c) (set! %seen (fx+ %seen 1))))))

(define (run)
  (show "run-outermost-unhooked" (ns-per-op keystroke))
  (fill!)
  (show "run-outermost" (ns-per-op keystroke))
  (show "run-outermost-bytes" (bytes-per-op keystroke))
  (show "run-nested" (ns-per-op (lambda () (commands:run nested))))
  (show "command?" (ns-per-op (lambda () (commands:command? counted))))
  (show "command-named" (ns-per-op (lambda () (commands:command-named 'bench/commands:counted)))))
