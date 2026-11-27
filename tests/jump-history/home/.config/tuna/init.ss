(import (hooks) (options) (timers))
(import (tuna) (document) (haml) (web))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin minibuffer)
(use-plugin jump-history)

(define client (web:add-client! 1))

(define (press! . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client client])
        (views:call-with-view (layout:selected-view) (lambda () (keys:press! client key)))))
    keys))

(define (view) (layout:selected-view))

;; A prompt pauses its task, so tests run it in a task of its own.
(define (start! thunk)
  (let ([t (spawn-task (lambda (restore) (parameterize ([web:current-client client]) (thunk))))])
    (timers:sleep 0.05)
    t))

(define (here) (cons (buffers:name (views:buffer (view))) (views:point (view))))

(define (places) (map (lambda (p) (cons (buffers:name (car p)) (cdr p))) (jump-history:places)))

(define (search-html s sub)
  (let loop ([i 0])
    (cond
      [(> (+ i (string-length sub)) (string-length s)) #f]
      [(string=? (substring s i (+ i (string-length sub))) sub) i]
      [else (loop (+ i 1))])))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))

(commands:define-command (show [b (buffers:current)])
  "Shows B in the selected view."
  (layout:switch-to-buffer b))

(commands:define-command (jump [b (buffers:current)] [position 0])
  "Shows B in the selected view at POSITION, recording the place it leaves."
  (let ([from (views:buffer (view))] [at (views:point (view))])
    (layout:switch-to-buffer b)
    (views:set-point! (view) position)
    (jump-history:push! from at)))

(define first (or (buffers:find "first") (buffers:make "first" "one\ntwo\nthree\n")))
(define second (or (buffers:find "second") (buffers:make "second" "four\nfive\n")))
(define third (or (buffers:find "third") (buffers:make "third" "six\n")))

;; A switch while the configuration loads runs in no command.
(layout:switch-to-buffer first)
(import (console))
