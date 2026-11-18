(import (tuna) (tuna plugins) (document) (haml) (web))
(use-plugin markdown
  (config
    (keys:bind! markdown:link-keys "C-c C-o" markdown:follow-link)))
(use-plugin editing)
(use-plugin layout)
(use-plugin undo)

(define client (web:add-client! 1))

(define (in-client thunk)
  (parameterize ([web:current-client client])
    (layout:call-with-frame (layout:frame client) thunk)))

(define (press! . keys)
  (for-each (lambda (key) (in-client (lambda () (keys:press! client key)))) keys))

(define (view) (layout:selected-view))

(define (show! b)
  (views:set-buffer! (view) b)
  (views:set-point! (view) 1))

(define (mouse-in! v action place . fields)
  (parameterize ([web:current-client client])
    ((table-ref web:input-handlers "mouse") client
     (append fields
             `(("type" . "mouse") ("action" . ,action) ("button" . 1) ("clicks" . 1) ("modifiers" . #())
               ("view" . ,(views:id v)) ("version" . ,(buffers:version (views:buffer v)))
               ("showing" . ,(views:shown-count v)) ("report" . 1)
               ,@place)))))

(define (click-at! v at) (mouse-in! v "down" `(("at" . ,at) ("count" . 0))) (mouse-in! v "click" `(("at" . ,at) ("count" . 0))))

(define (text b) (document:text (buffers:document b)))

(define (datums b) (document:datums (buffers:document b)))

(define (html v) (html->string (views:draw v client)))

(define (element v start tag)
  (let* ([s (html v)] [open (string-append "<" tag)] [close (string-append "</" tag ">")])
    (define (at? sub i)
      (and (<= (+ i (string-length sub)) (string-length s)) (string=? (substring s i (+ i (string-length sub))) sub)))
    (define (search sub from)
      (let loop ([i from]) (cond [(> i (string-length s)) #f] [(at? sub i) i] [else (loop (+ i 1))])))
    (let ([i (search start 0)])
      (and i
           (let loop ([j (+ i 1)] [depth 1])
             (cond
               [(at? close j) (if (= depth 1) (substring s i (+ j (string-length close))) (loop (+ j 1) (- depth 1)))]
               [(at? open j) (loop (+ j 1) (+ depth 1))]
               [(>= j (string-length s)) #f]
               [else (loop (+ j 1) depth)]))))))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))
(import (console))
