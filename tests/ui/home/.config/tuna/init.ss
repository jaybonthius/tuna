(import (tuna) (testing) (tuna plugins) (document) (haml) (web))
(use-plugin ui)
(use-plugin editing)
(use-plugin layout)
(use-plugin layout-split)
(use-plugin files)
(use-plugin undo)

(define client (web:add-client! 1))

(define (in-client thunk)
  (parameterize ([web:current-client client])
    (views:call-with-view (layout:selected-view) thunk)))

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

;; The browser sends a token's position for a click on an atom or a
;; node's element.
(define (click-token! v at) (mouse-in! v "down" `(("token" . ,at))) (mouse-in! v "click" `(("token" . ,at))))

(define (click-at! v at) (mouse-in! v "down" `(("at" . ,at) ("count" . 0))) (mouse-in! v "click" `(("at" . ,at) ("count" . 0))))

(define (text b) (document:text (buffers:document b)))

(define (datums b) (document:datums (buffers:document b)))

(define (html v) (html->string (views:draw v client)))

(define (element v start tag)
  (let* ([s (html v)] [close (string-append "</" tag ">")])
    (define (search sub from)
      (let loop ([i from])
        (cond
          [(> (+ i (string-length sub)) (string-length s)) #f]
          [(string=? (substring s i (+ i (string-length sub))) sub) i]
          [else (loop (+ i 1))])))
    (let ([i (search start 0)])
      (and i (substring s i (+ (search close i) (string-length close)))))))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))

(import (console))
