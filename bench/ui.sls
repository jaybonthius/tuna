#!tuna
(import (document) (buffers) (views) (keys) (commands) (layout) (undo) (ui) (web) (haml))

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

(define (show name value)
  (printf "~a ~,2f\n" name value))

(define client (web:add-client! 1))

(define (in-client thunk)
  (parameterize ([web:current-client client])
    (layout:call-with-frame (layout:frame client) thunk)))

(define handle (table-ref web:input-handlers "mouse"))

(define (click view at)
  (let ([it `(("type" . "mouse") ("action" . "click") ("button" . 1) ("clicks" . 1) ("modifiers" . #())
              ("report" . 1) ("view" . ,(views:id view)) ("version" . ,(buffers:version (views:buffer view)))
              ("showing" . ,(views:shown-count view)) ("token" . ,at))])
    (lambda () (parameterize ([web:current-client client]) (handle client it)))))

(define pushed 0)

(define (ignore row) (void))

(commands:define-command (push) "Counts a push." (set! pushed (fx+ pushed 1)))

(ui:define-button go push)

(define (candidate i) (vector (format "candidate-~a.ss" i) (format "~a lines" (* 7 i))))

(define (draw-candidate c) (ui:row (ui:label (vector-ref c 0)) (ui:label (vector-ref c 1) "detail")))

(define (candidates) (let ([v (make-vector 100000)]) (do ([i 0 (fx+ i 1)]) ((fx= i 100000) v) (vector-set! v i (candidate i)))))

(define (run)
  (let* ([b (buffers:make "*candidates*" (ui:list '()))] [v (layout:selected-view)] [rows (candidates)] [other (candidates)])
    (define (node) (document:token (buffers:document b) 0))
    ;; A list's buffer keeps no undo history, since its rows are rebuilt
    ;; from data the list's maker holds.
    (buffers:with-buffer b (set-option-local! undo:limit 0))
    (views:set-buffer! v b)
    (ui:set-rows! b (node) rows draw-candidate ignore 15)
    (show "ui-draw-list" (ns-per-op (lambda () (html->bytevector (views:draw v client)))))
    (show "ui-next-row" (/ (ns-per-op (lambda () (in-client (lambda () (keys:press! client "C-n") (keys:press! client "C-p"))))) 2))
    (show "ui-select-row-slide" (/ (ns-per-op (lambda () (ui:select-row! (node) v 15) (ui:select-row! (node) v 0))) 2))
    (show "ui-set-rows" (/ (ns-per-op (lambda () (ui:set-rows! b (node) other draw-candidate ignore 15) (ui:set-rows! b (node) rows draw-candidate ignore 15))) 2))
    (ui:select-row! (node) v 0)
    (let ([c (click v 3)])
      (show "ui-click-row" (ns-per-op c)))
    (let ([t (buffers:make "*button*" (buffers:text '() "Run " (go '() "Go") "\n"))])
      (buffers:with-buffer t (set-option-local! undo:limit 0))
      (views:set-buffer! v t)
      (let ([c (click v 6)])
        (show "ui-click-button" (ns-per-op c))
        (unless (fx>= pushed batch) (printf "the button was not pushed\n"))))
    (in-client (lambda () (commands:run ui:showcase)))
    (show "ui-draw-showcase" (ns-per-op (lambda () (html->bytevector (views:draw v client)))))))
