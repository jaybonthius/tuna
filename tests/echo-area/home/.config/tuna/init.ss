(import (tuna) (tuna plugins) (document) (haml) (web) (layout-split))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin echo-area
  (config
    (set-option! echo-area:log-max 16384)))
(use-plugin files)
(use-plugin undo)

(define client (web:add-client! 1))

(define other-client (web:add-client! 2))

(define (in-client thunk)
  (parameterize ([web:current-client client])
    (views:call-with-view (layout:selected-view) thunk)))

(define (press-in! c . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client c])
        (views:call-with-view (layout:selected-view) (lambda () (keys:press! c key)))))
    keys))

(define (press! . keys) (apply press-in! client keys))

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

(define (view) (layout:selected-view))

(define (text b) (document:text (buffers:document b)))

(define (messages) (text (buffers:find "*Messages*")))

(define echo-buffer (buffers:find " *Echo Area*"))

(define (echo-view) (car (views:showing echo-buffer)))

(define (echo-area-element) (echo-area-element-for client))

(define (echo-area-element-for c)
  (let* ([s (html->string (views:draw (echo-view) c))] [open "<div class=\"echo-area-message\""] [close "</div></div>"])
    (define (search sub from)
      (let loop ([i from])
        (cond
          [(> (+ i (string-length sub)) (string-length s)) #f]
          [(string=? (substring s i (+ i (string-length sub))) sub) i]
          [else (loop (+ i 1))])))
    (let ([i (search open 0)])
      (and i (substring s i (+ (search close i) (string-length close)))))))

(define (tree) (car (document:datums (buffers:document layout:buffer))))

(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 1000))
      (sleep-for 0.01)
      (loop (+ n 1)))))

(define (on-thread thunk)
  (let ([result #f] [done #f])
    (fork-thread (lambda () (set! result (guard (c [#t (list (condition-who c) (condition-message c))]) (thunk))) (set! done #t)))
    (wait-until (lambda () done))
    result))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))
(import (console))
