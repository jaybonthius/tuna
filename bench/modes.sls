#!tuna
(import (modes) (auto-mode) (layout) (views) (buffers) (keys) (commands) (web))

(define (now-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (median xs)
  (list-ref (list-sort < xs) (quotient (length xs) 2)))

(define (ns-per-op batch thunk)
  (median
    (map (lambda (k)
           (collect-rendezvous)
           (let ([start (now-ns)])
             (do ([i 0 (fx+ i 1)]) ((fx= i batch)) (thunk))
             (/ (- (now-ns) start) (exact->inexact batch))))
         (iota 9))))

(define (bytes-per-op batch thunk)
  (let ([before (sstats-bytes (statistics))])
    (do ([i 0 (fx+ i 1)]) ((fx= i batch)) (thunk))
    (/ (- (sstats-bytes (statistics)) before) (exact->inexact batch))))

(define (show name value unit)
  (printf "~a ~,2f ~a\n" name value unit))

(define-table prog-keymap)
(define-hook prog-hook)
(define-table bench-keymap)
(define-hook bench-hook)
(define-table leaf-keymap)
(define-hook leaf-hook)

(modes:define-major-mode prog (keymap prog-keymap) (hook prog-hook))
(modes:define-major-mode bench (parent prog) (keymap bench-keymap) (hook bench-hook))
(modes:define-major-mode leaf (parent bench) (keymap leaf-keymap) (hook leaf-hook))

(define-option o0 #f boolean?) (define-option o1 #f boolean?) (define-option o2 #f boolean?)
(define-option o3 #f boolean?) (define-option o4 #f boolean?) (define-option o5 #f boolean?)
(define-option o6 #f boolean?) (define-option o7 #f boolean?) (define-option o8 #f boolean?)
(define-option o9 #f boolean?) (define-option o10 #f boolean?) (define-option o11 #f boolean?)
(define-option o12 #f boolean?) (define-option o13 #f boolean?) (define-option o14 #f boolean?)
(define-option o15 #f boolean?) (define-option o16 #f boolean?) (define-option o17 #f boolean?)
(define-option o18 #f boolean?) (define-option o19 #f boolean?) (define-option o20 #f boolean?)
(define-option o21 #f boolean?) (define-option o22 #f boolean?) (define-option o23 #f boolean?)
(define-option o24 #f boolean?) (define-option o25 #f boolean?) (define-option o26 #f boolean?)
(define-option o27 #f boolean?) (define-option o28 #f boolean?) (define-option o29 #f boolean?)

(define minor
  (list o0 o1 o2 o3 o4 o5 o6 o7 o8 o9 o10 o11 o12 o13 o14 o15 o16 o17 o18 o19
        o20 o21 o22 o23 o24 o25 o26 o27 o28 o29))

(define-option width 8 fixnum?)

(define-table k0)
(define-table k1)
(define-table k2)

(commands:define-command (nothing) "Does nothing." #f)

(define (run)
  (let* ([client (web:add-client! 1)]
         [b (buffers:make "foo.ss" "(display 1)\n")])
    (for-each
      (lambda (m i)
        (table-set! modes:minor-modes m (mod i 3))
        (table-set! modes:keymaps m (list-ref (list k0 k1 k2) (mod i 3))))
      minor (iota 30))
    (layout:switch-to-buffer b)
    (modes:set-major-mode leaf b)
    (buffers:with-buffer b (set-option-local! o3 #t o11 #t o20 #t))
    (keys:bind! keys:global "a" nothing)
    (let ([view (layout:selected-view)] [frame (layout:frame client)])
      (show "active-keymaps"
        (views:with-view view (ns-per-op 20000 (lambda () (modes:active-keymaps client #f))))
        "ns")
      (show "active-keymaps-bytes"
        (views:with-view view (bytes-per-op 20000 (lambda () (modes:active-keymaps client #f))))
        "B")
      (show "active-minor-modes" (ns-per-op 20000 (lambda () (modes:active-minor-modes view))) "ns")
      (parameterize ([web:current-client client])
        (let ([press (lambda () (layout:call-with-frame frame (lambda () (keys:press! client "a"))))])
          (show "press-key-with-modes" (ns-per-op 2000 press) "ns")
          (remove-hook! keys:find-keymaps modes:active-keymaps)
          (show "press-key-without-modes" (ns-per-op 2000 press) "ns")
          (add-hook! keys:find-keymaps modes:active-keymaps 50))))
    (let ([empty (map (lambda (i) (lambda () i)) (iota 10))]
          [setting (map (lambda (i) (lambda () (set-option-local! width 2) i)) (iota 10))])
      (for-each (lambda (entry) (add-hook! leaf-hook entry)) empty)
      (show "set-major-mode" (ns-per-op 2000 (lambda () (modes:set-major-mode leaf b))) "ns")
      (show "run-mode-hooks" (ns-per-op 2000 (lambda () (modes:run-mode-hooks b))) "ns")
      (for-each (lambda (entry) (remove-hook! leaf-hook entry)) empty)
      (for-each (lambda (entry) (add-hook! leaf-hook entry)) setting)
      (modes:set-major-mode leaf b)
      (show "run-mode-hooks-setting" (ns-per-op 2000 (lambda () (modes:run-mode-hooks b))) "ns")
      (show "set-option-local-unchanged"
        (buffers:with-buffer b (ns-per-op 20000 (lambda () (set-option-local! width 2)))) "ns"))
    (table-set! auto-mode:file-names "ss" leaf)
    (show "choose" (ns-per-op 20000 (lambda () (auto-mode:choose b))) "ns")))
