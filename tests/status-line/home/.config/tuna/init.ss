(import (options) (tables) (timers) (plugins))
(import (tuna) (document) (haml) (web) (layout-split))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin modes)
(use-plugin status-line
  (config
    (when (equal? (getenv "TRANSCRIPT") "examples")
      (tables:remove! status-line:segments status-line:minor-modes)
      (tables:set! status-line:segments status-line:position (status-line:right 90)))))
(use-plugin files)
(use-plugin editing)
(use-plugin undo)
(use-plugin fill)
(use-plugin python)

(define client (web:add-client! 1))

(define other-client (web:add-client! 2))

(define (in-client thunk)
  (parameterize ([web:current-client client])
    (views:call-with-view (layout:selected-view) thunk)))

(define (press! . keys)
  (for-each (lambda (key) (in-client (lambda () (keys:press! client key)))) keys))

(define (view) (layout:selected-view))

(define (text b) (document:text (buffers:document b)))

(define (tree) (car (document:datums (buffers:document layout:buffer))))

(define (search s sub from)
  (let loop ([i from])
    (cond
      [(> (+ i (string-length sub)) (string-length s)) #f]
      [(string=? (substring s i (+ i (string-length sub))) sub) i]
      [else (loop (+ i 1))])))

(define (segments-in html)
  (let loop ([from 0] [acc '()])
    (let ([i (search html "data-segment=\"" from)])
      (if i
          (let* ([name-end (search html "\"" (+ i 14))] [open-end (search html ">" name-end)]
                 [next (or (search html "data-segment=\"" open-end) (string-length html))])
            (loop next
                  (cons (cons (substring html (+ i 14) name-end)
                              (strip-tags (substring html (+ open-end 1) next)))
                        acc)))
          (reverse acc)))))

(define (strip-tags s)
  (let loop ([cs (string->list s)] [in? #f] [acc '()])
    (cond
      [(null? cs) (list->string (reverse acc))]
      [(char=? (car cs) #\<) (loop (cdr cs) #t acc)]
      [(char=? (car cs) #\>) (loop (cdr cs) #f acc)]
      [in? (loop (cdr cs) #t acc)]
      [else (loop (cdr cs) #f (cons (car cs) acc))])))

(define (status v) (let ([h (status-line:draw v client)]) (and h (segments-in (html->string h)))))

(define (screen-status-lines c)
  (let ([s (html->string (layout:screen c))])
    (let loop ([from 0] [acc '()])
      (let ([i (search s "<footer class=\"status-line\"" from)])
        (if i
            (let ([e (search s "</footer>" i)])
              (loop e (cons (segments-in (substring s i e)) acc)))
            (reverse acc))))))

;; The page sends a marked keymap's number, before its state.
(define (mark-number keymap) (read (open-input-string (views:keymap-mark keymap))))

(define (click-status! window button . keymaps)
  (let ([s layout:screen-view] [at (document:node-start (layout:view-node window))])
    (for-each
      (lambda (action)
        (parameterize ([web:current-client client])
          ((tables:ref web:input-handlers "mouse") client
           `(("type" . "mouse") ("action" . ,action) ("button" . ,button) ("clicks" . 1) ("modifiers" . #())
             ("view" . ,(views:id s)) ("version" . ,(buffers:version layout:buffer))
             ("showing" . ,(views:shown-count s)) ("token" . ,at)
             ("keymaps" . ,(list->vector (map mark-number (append keymaps (list status-line:keymap)))))))))
      '("down" "click"))))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))
(import (console))
