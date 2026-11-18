(import (tuna) (tuna plugins) (web) (keys) (commands) (harpo))
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
    (set-option! lossage:size 1000)))

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
        (layout:call-with-frame (layout:frame c) (lambda () (keys:press! c key)))))
    keys))

(define (press! . keys) (apply press-in! client keys))

(define (in-client thunk)
  (parameterize ([web:current-client client])
    (layout:call-with-frame (layout:frame client) thunk)))

;; A command's prompt pauses its task, so tests run it in a task of its
;; own and wait for the prompt.
(define (start! thunk)
  (let ([t (spawn-task (lambda () (in-client thunk)))])
    (sleep-for 0.05)
    t))

(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 500))
      (sleep-for 0.01)
      (loop (+ n 1)))))

(define (result t)
  (wait-until (lambda () (task-done? t)))
  (if (task-done? t) (join-task t) 'waiting))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))

(define (on-thread thunk)
  (let ([done #f])
    (fork-thread (lambda () (set! done (list (thunk)))))
    (wait-until (lambda () done))
    (car done)))

(define mark 0)

(define (mark!) (set! mark (length (lossage:recent-keys))))

(define (since-mark) (list-tail (lossage:recent-keys) mark))
(import (console))
