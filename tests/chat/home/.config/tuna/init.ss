(import (tuna) (tuna plugins) (tuna eval) (document) (haml) (web))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin undo)
(use-plugin minibuffer)
(use-plugin status-line)
(use-plugin files)
(use-plugin kill-ring)
(use-plugin fake-agents)

(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 500))
      (sleep-for 0.01)
      (loop (+ n 1)))))

(define client (web:add-client! 1))

(define (in-client thunk)
  (parameterize ([web:current-client client])
    (views:call-with-view (layout:selected-view) thunk)))

(define (press! . keys)
  (for-each (lambda (key) (in-client (lambda () (keys:press! client key)))) keys))

(define (type! text)
  (for-each (lambda (c) (press! (case c [(#\space) "SPC"] [(#\newline) "S-RET"] [else (string c)]))) (string->list text)))

(define (run! command) (in-client (lambda () (commands:run command))))

(define (view) (layout:selected-view))

(define (shown c) (document:text (buffers:document (chat:buffer c))))

(define (settle) (sleep-for 0.05))

(define (raised thunk)
  (guard (c [(not (quit-condition? c)) (list 'raised (if (message-condition? c) (condition-message c) c))])
    (thunk)))

;; The page sends a marked keymap's number, before its state.
(define (mark-number keymap) (read (open-input-string (views:keymap-mark keymap))))

(define (click-status! window . keymaps)
  (let ([s layout:screen-view] [at (document:node-start (layout:view-node window))])
    (for-each
      (lambda (action)
        (parameterize ([web:current-client client])
          ((table-ref web:input-handlers "mouse") client
           `(("type" . "mouse") ("action" . ,action) ("button" . 1) ("clicks" . 1) ("modifiers" . #())
             ("view" . ,(views:id s)) ("version" . ,(buffers:version layout:buffer))
             ("showing" . ,(views:shown-count s)) ("token" . ,at)
             ("keymaps" . ,(list->vector (map mark-number (append keymaps (list status-line:keymap)))))))))
      '("down" "click"))))
(import (console))
