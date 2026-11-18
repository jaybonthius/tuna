(import (tuna) (tuna plugins) (document) (haml) (web) (layout-sides))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin modes)
(use-plugin status-line
  (config
    (when (equal? (getenv "TRANSCRIPT") "examples")
      (table-remove! status-line:segments status-line:minor-modes)
      (table-set! status-line:segments status-line:position (status-line:right 90)))))
(use-plugin files)
(use-plugin editing)
(use-plugin undo)
(use-plugin fill)
(use-plugin python)

(define client (web:add-client! 1))

(define other-client (web:add-client! 2))

(define (in-client thunk)
  (parameterize ([web:current-client client])
    (layout:call-with-frame (layout:frame client) thunk)))

(define (press! . keys)
  (for-each (lambda (key) (in-client (lambda () (keys:press! client key)))) keys))

(define (view) (layout:selected-view))

(define (text b) (document:text (buffers:document b)))

(define (tree) (car (document:datums (buffers:document layout:buffer))))

(define line-buffer (buffers:find " *status-line*"))

(define (line) (car (document:datums (buffers:document line-buffer))))

;; Views number their placements from a random base.
(define (hide-placements s)
  (let loop ([s s] [from 0])
    (let ([i (let find ([i from])
               (cond
                 [(> (+ i 16) (string-length s)) #f]
                 [(string=? (substring s i (+ i 16)) "data-placement=\"") i]
                 [else (find (+ i 1))]))])
      (if i
          (let end ([j (+ i 16)])
            (if (char=? (string-ref s j) #\")
                (loop (string-append (substring s 0 (+ i 16)) "*" (substring s j (string-length s))) (+ i 17))
                (end (+ j 1))))
          s))))

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
                 [close (let ([span (search html "</span></div>" open-end)] [button (search html "</button></div>" open-end)])
                          (if (and button (or (not span) (< button span))) button span))])
            (loop close
                  (cons (cons (substring html (+ i 14) name-end)
                              (strip-tags (substring html (+ open-end 1) close)))
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

(define (screen) (hide-placements (html->string (layout:screen client))))

(define (screen-status-lines c)
  (let ([s (html->string (layout:screen c))])
    (let loop ([from 0] [acc '()])
      (let ([i (search s "<footer class=\"status-line\">" from)])
        (if i
            (let ([e (search s "</footer>" i)])
              (loop e (cons (segments-in (substring s i e)) acc)))
            (reverse acc))))))

(define (status-view-of window)
  (find (lambda (sv) (eq? (status-line:posn-view (views:%make-posn sv 1)) window))
        (views:showing line-buffer)))

(define (mouse-in! v action place)
  (parameterize ([web:current-client client])
    ((table-ref web:input-handlers "mouse") client
     (append place
             `(("type" . "mouse") ("action" . ,action) ("button" . 1) ("clicks" . 1) ("modifiers" . #())
               ("view" . ,(views:id v)) ("version" . ,(buffers:version (views:buffer v)))
               ("showing" . ,(views:shown-count v)) ("report" . 1))))))

(define (click-token! v at . version)
  (let ([place (cons* (cons "token" at) (if (null? version) '() (list (cons "version" (car version)))))])
    (mouse-in! v "down" place)
    (mouse-in! v "click" place)))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))
(import (console))
