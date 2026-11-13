#!tuna
(import (commands) (keys) (web))

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

(define seen 0)

(commands:define-command (nothing) "Does nothing." #f)

(commands:define-command (insert [n (commands:prefix-number)])
  "Takes the prefix number and the character typed."
  (keys:typed-char)
  n)

(define-table m0)
(define-table m1)
(define-table m2)
(define-table m3)
(define-table m4)
(define-table m5)
(define-table m6)
(define-table m7)
(define-table m8)

(define focus-path (list m0 m1 m2 m3 m4 m5 m6 m7 m8))

(define (letter i) (string (integer->char (+ 97 (mod i 26)))))

;; Ten keymaps with 1,270 bindings, as a buffer's kind, its modes, the
;; layout's containers and the global keymap would give: 300 global
;; ones and 970 spread over the nine of the focus path, each with
;; printing characters, prefixes and longer sequences.
(define (fill!)
  (do ([i 0 (fx+ i 1)]) ((fx= i 285))
    (keys:bind! keys:global (format "C-c ~a ~a" (letter (quotient i 26)) (letter i)) nothing))
  (for-each
    (lambda (m k)
      (do ([i 0 (fx+ i 1)]) ((fx= i (if (fx= k 0) 106 108)))
        (keys:bind! m (format "C-~a ~a ~a" (letter (+ k 3)) (letter (quotient i 26)) (letter i)) nothing)))
    focus-path (iota 9))
  (keys:bind! keys:global "<printing-char>" insert)
  (keys:bind! keys:global "C-x C-f" nothing)
  (add-hook! keys:find-keymaps (lambda (frame) focus-path))
  (do ([i 0 (fx+ i 1)]) ((fx= i 3))
    (add-hook! commands:before-command (lambda (c) (set! seen (fx+ seen 1))))
    (add-hook! commands:after-command (lambda (c) (set! seen (fx+ seen 1))))))

(define item '(("type" . "key") ("key" . "≈") ("code" . "KeyX") ("modifiers" . #("control" "left-option"))))

(define frame 'frame)

(define (run)
  (fill!)
  (show "bindings" (fold-left + 0 (map (lambda (m) (length (keys:bindings m))) (keys:active-keymaps frame))))
  (show "item-key" (ns-per-op (lambda () (keys:item-key item))))
  (show "lookup-key" (ns-per-op (lambda () (keys:lookup frame "C-l"))))
  (show "lookup-three-keys" (ns-per-op (lambda () (keys:lookup frame "C-l d x"))))
  (show "lookup-global" (ns-per-op (lambda () (keys:lookup frame "C-c k d"))))
  (show "press-printing-char" (ns-per-op (lambda () (keys:press! frame "a"))))
  (show "press-two-keys" (ns-per-op (lambda () (keys:press! frame "C-x") (keys:press! frame "C-f"))))
  (web:connect! (web:make-client 1))
  (batch-ended)
  (show "batch-ended-one-client" (ns-per-op batch-ended))
  (let ([press (bytes-per-op (lambda () (keys:press! frame "a")))]
        [run (bytes-per-op (lambda () (commands:run insert)))])
    (show "press-printing-char-bytes" press)
    (show "commands-run-bytes" run)
    (show "press-bytes-beyond-run" (- press run))))
