(import (hooks) (options) (timers) (plugins))
(import (tuna) (testing) (web) (keys) (commands))
;; Loaded, not imported, so its unload in a test stays an unload.
(load-module! '(harpo))
(use-plugin layout)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin minibuffer)
(use-plugin completion)
(use-plugin files)
(use-plugin file-picker)
(use-plugin command-picker)
(use-plugin lossage
  (config
    (options:set! lossage:size 1000)))

(keys:bind! keys:global "<f5>" harpo:honk)
(keys:bind! keys:global "C-c h" harpo:honk-twice)
(keys:bind! keys:global "<mouse-1>" harpo:honk)
(keys:bind! keys:global "<mouse-movement>" harpo:honk)

(define client (web:add-client! 1))

(define other-client (web:add-client! 2))

(define (press-in! c . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client c])
        (views:call-with-view (layout:selected-view) (lambda () (keys:press! c key)))))
    keys))

(define (press! . keys) (apply press-in! client keys))

(define (in-client thunk)
  (parameterize ([web:current-client client])
    (views:call-with-view (layout:selected-view) thunk)))

;; A command's prompt pauses its task, so tests run it in a task of its
;; own and wait for the prompt.
(define (start! thunk)
  (let ([t (spawn-task (lambda (restore) (in-client thunk)))])
    (timers:sleep 0.05)
    t))


(define (result t)
  (testing:wait-until (lambda () (eq? (task-state t) 'done)))
  (if (eq? (task-state t) 'done) (testing:join t) 'waiting))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))

(define (on-thread thunk)
  (let ([done #f])
    (fork-task (lambda (restore) (set! done (list (thunk)))))
    (testing:wait-until (lambda () done))
    (car done)))

(define mark 0)

(define (mark!) (set! mark (length (lossage:recent-keys))))

(define (since-mark) (list-tail (lossage:recent-keys) mark))
(import (console))
