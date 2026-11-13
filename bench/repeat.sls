#!tuna
(import (commands) (keys) (repeat) (web))

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
  (let ([before (sstats-bytes (statistics))])
    (do ([i 0 (fx+ i 1)]) ((fx= i batch)) (thunk))
    (/ (- (sstats-bytes (statistics)) before) (exact->inexact batch))))

(define (show name value)
  (printf "~a ~,2f\n" name value))

(commands:define-command (nothing) "Does nothing." #f)

(commands:define-command (step) "Does nothing, repeatedly." #f)

(define-table k0)
(define-table k1)
(define-table k2)
(define-table k3)
(define-table k4)
(define-table k5)
(define-table k6)
(define-table k7)
(define-table k8)
(define-table k9)
(define-table k10)
(define-table k11)
(define-table k12)
(define-table k13)
(define-table k14)
(define-table k15)
(define-table k16)
(define-table k17)
(define-table k18)
(define-table k19)
(define-table k20)
(define-table k21)
(define-table k22)

(define others (list k0 k1 k2 k3 k4 k5 k6 k7 k8 k9 k10 k11 k12 k13 k14 k15 k16 k17 k18 k19 k20 k21 k22))

(define-table stepping)

(define-table stepping-last)

(define client (web:make-client 1))

(define (press! key) (keys:press! client key))

(define (two-keys) (press! "C-x") (press! "C-f"))

(define (run)
  (keys:bind! keys:global "C-x C-f" nothing)
  (keys:bind! keys:global "a" nothing)
  (keys:bind! keys:global "C-c n" step)
  (parameterize ([web:current-client client])
    (let ([before (ns-per-op two-keys)] [one-key-bytes (bytes-per-op (lambda () (press! "a")))])
      (keys:bind! stepping "n" step)
      (table-set! repeat:keymaps stepping)
      (show "repeat-search-one-keymap" (- (ns-per-op two-keys) before))
      (for-each
        (lambda (keymap i)
          (keys:bind! keymap (string (integer->char (+ 97 i))) nothing)
          (keys:bind! keymap "z" nothing)
          (table-set! repeat:keymaps keymap))
        others (iota (length others)))
      (show "press-one-key" (ns-per-op (lambda () (press! "a"))))
      (show "press-two-keys" (ns-per-op two-keys))
      (show "repeat-search-24-keymaps" (- (ns-per-op two-keys) before))
      ;; Emacs's own Lisp declares 24 repeating keymaps. A table lists its
      ;; keys in the order they were first set, so the one that repeats is
      ;; set after the others, and entering it searches through all of them.
      (table-remove! repeat:keymaps stepping)
      (keys:bind! stepping-last "n" step)
      (table-set! repeat:keymaps stepping-last)
      (show "enter-repeat" (ns-per-op (lambda () (press! "C-c") (press! "n"))))
      (press! "C-c")
      (press! "n")
      (show "repeated-key" (ns-per-op (lambda () (press! "n"))))
      (show "repeated-key-bytes-beyond-press" (- (bytes-per-op (lambda () (press! "n"))) one-key-bytes)))))
