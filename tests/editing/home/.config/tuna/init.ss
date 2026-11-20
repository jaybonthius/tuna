(import (tuna) (tuna plugins) (document) (web) (md) (layout-split))
;; ask's own writer raises each message as a warning, whose handler runs
;; outside the guards of the code that said it; the tests keep the
;; messages to read them.
(define said '())
(use-plugin ask
  (config
    (set-option! ask:message-writer (lambda (text) (set! said (cons text said))))))
(define (take-said!) (let ([s (reverse said)]) (set! said '()) s))
(use-plugin editing
  (config
    (set-option! editing:delete-selection #t)))
(use-plugin layout)

(define client (web:add-client! 1))

(define (press! . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client client])
        (views:call-with-view (layout:selected-view)
          (lambda () (keys:press! client key)))))
    keys))

(define (points-after . keys)
  (let loop ([keys keys] [acc '()])
    (if (null? keys)
        (reverse acc)
        (begin (press! (car keys)) (loop (cdr keys) (cons (views:point (view)) acc))))))

(define (view) (layout:selected-view))

(define (text) (document:text (buffers:document (views:buffer (view)))))

(define (cursors)
  (map (lambda (c) (list (views:cursor-point c) (views:cursor-mark c))) (views:cursors (view))))

(define (state) (list (text) (cursors)))

(define start!
  (let ([n 0])
    (lambda (content . points)
      (set! n (+ n 1))
      (let ([b (buffers:make (format "t~a" n) content)] [v (view)])
        (views:set-buffer! v b)
        (views:set-point! v (car points))
        (for-each (lambda (p) (views:add-cursor! v p)) (cdr points))
        (state)))))

(define (kills n) (map kill-ring:text (list-head (kill-ring:entries) n)))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))

(define (run command . args)
  (parameterize ([web:current-client client])
    (views:call-with-view (layout:selected-view)
      (lambda () (apply commands:run command args)))))
(import (console))
