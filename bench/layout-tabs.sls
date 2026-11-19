#!tuna
(import (layout) (layout-split) (layout-tabs) (views) (buffers) (document) (commands) (web) (haml))

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

(define (show name value)
  (printf "~a ~,2f\n" name value))

(define (atom b)
  (views:view (list (cons 'view (views:id (views:make b))) (cons 'buffer (buffers:name b)))))

;; Eleven tabs, each a row of three views, as many parts as the layout
;; benchmark's splits.
(define (build! notes)
  (let ([n (document:length (buffers:document layout:buffer))])
    (buffers:replace! layout:buffer 1 (- n 1)
      (document:from-datum
        (apply layout-tabs:container '()
               (map (lambda (i) (layout-split:container '((direction . row)) (atom notes) (atom notes) (atom notes)))
                    (iota 11))))))
  (layout:select! (car (layout:views)))
  ((layout-split:display-at-side (layout:direction down) 90 (quote content) (quote ((locked . #t)))) (buffers:make "*Echo*" "")))

(define (parts)
  (let count ([d (car (document:datums (buffers:document layout:buffer)))])
    (if (vector? d) 1 (+ 1 (apply + (map count (cddr d)))))))

(define (tabs-node doc)
  (let ([row (document:enclosing doc (document:node-start (layout:view-node (car (layout:views)))))])
    (document:enclosing doc (document:node-start row))))

(define (label k)
  (let ([doc (buffers:document layout:buffer)])
    (let loop ([at (fx+ (document:node-start (tabs-node doc)) 1)] [k k])
      (let ([child (document:token doc at)])
        (if (fx= k 0) (document:node-start child) (loop (document:node-end child) (fx- k 1)))))))

(define (run)
  (let* ([notes (buffers:make "notes" "one\ntwo\nthree\n")]
         [client (web:add-client! 1)]
         [mouse (table-ref web:input-handlers "mouse")])
    (build! notes)
    (batch-ended)
    (show "parts" (parts))
    (show "tabs-window-command"
      (/ (ns-per-op 200
           (lambda ()
             (commands:run layout-tabs:new-tab)
             (batch-ended)
             (commands:run layout-tabs:close-tab)
             (batch-ended)))
         2))
    (show "tabs-next-tab"
      (ns-per-op 200 (lambda () (commands:run layout-tabs:next-tab 1) (batch-ended))))
    (show "tabs-label-click"
      (let ([s layout:screen-view])
        (define (click! k)
          (parameterize ([web:current-client client])
            (for-each
              (lambda (action)
                (mouse client
                  `(("type" . "mouse") ("action" . ,action) ("button" . 1) ("clicks" . 1) ("modifiers" . #())
                    ("token" . ,(label k)) ("keymaps" . ,(vector (views:keymap-mark layout-tabs:keymap))) ("view" . ,(views:id s))
                    ("version" . ,(buffers:version layout:buffer)) ("showing" . ,(views:shown-count s)))))
              '("down" "click")))
          (batch-ended))
        (/ (ns-per-op 200 (lambda () (click! 2) (click! 3))) 2)))
    (advice-add! views:draw (lambda (draw view client) (haml (:div))))
    (show "tabs-screen-parts" (ns-per-op 200 (lambda () (html->bytevector (layout:screen client)))))))
