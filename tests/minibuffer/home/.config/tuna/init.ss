(import (tuna) (tuna plugins) (document) (haml) (web))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin undo)
(use-plugin minibuffer
  (config
    (set-option! minibuffer:history-length 300)))

(define client (web:add-client! 1))

(define other-client (web:add-client! 2))

(define (press-in! c . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client c])
        (layout:call-with-frame (layout:frame c) (lambda () (keys:press! c key)))))
    keys))

(define (press! . keys) (apply press-in! client keys))

(define (type! text)
  (for-each (lambda (c) (press! (if (char=? c #\space) "SPC" (string c)))) (string->list text)))

(define (in-client thunk)
  (parameterize ([web:current-client client])
    (layout:call-with-frame (layout:frame client) thunk)))

;; A command's prompt pauses its task, so tests run it in a task of its
;; own and wait for the prompt.
(define (start! thunk)
  (let ([t (spawn-task (lambda () (in-client thunk)))])
    (sleep-for 0.05)
    t))

(define (result t)
  (wait-until (lambda () (task-done? t)))
  (if (task-done? t)
      (guard (c [#t (list 'raised (if (message-condition? c) (condition-message c) c))])
        (join-task t))
      'waiting))

(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 500))
      (sleep-for 0.01)
      (loop (+ n 1)))))

(define (view) (layout:selected-view))

(define (text b) (document:text (buffers:document b)))

(define minibuf (buffers:find " *Minibuf*"))

(define (datums b) (document:datums (buffers:document b)))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))
(define (mouse-in! v action place)
  (parameterize ([web:current-client client])
    ((table-ref web:input-handlers "mouse") client
     (append place
             `(("type" . "mouse") ("action" . ,action) ("button" . 1) ("clicks" . 1) ("modifiers" . #())
               ("view" . ,(views:id v)) ("version" . ,(buffers:version (views:buffer v)))
               ("showing" . ,(views:shown-count v)) ("report" . 1))))))

(define (click-at! v at)
  (mouse-in! v "down" `(("at" . ,at) ("count" . 0)))
  (mouse-in! v "click" `(("at" . ,at) ("count" . 0))))

(define (prompt) (minibuffer:current-prompt))

(define (input) (minibuffer:input (prompt)))

(define (bar) (layout:find-view minibuf))

;; The view's own element carries a placement number that differs from
;; run to run, so tests compare what the prompts draw.
(define (html v)
  (let* ([s (html->string (views:draw v client))] [open "<div class=\"minibuffer-prompts\">"])
    (let loop ([i 0])
      (cond
        [(> (+ i (string-length open)) (string-length s)) s]
        [(string=? (substring s i (+ i (string-length open))) open) (substring s i (- (string-length s) 12))]
        [else (loop (+ i 1))]))))

(import (console))
