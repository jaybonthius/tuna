(import (tuna) (tuna plugins) (document) (haml) (web))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin layout-float)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin undo)
(use-plugin minibuffer)
(use-plugin transient)

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

(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 500))
      (sleep-for 0.01)
      (loop (+ n 1)))))

(define (result t)
  (wait-until (lambda () (task-done? t)))
  (if (task-done? t)
      (guard (c [#t (list 'raised (if (message-condition? c) (condition-message c) c))])
        (join-task t))
      'waiting))

(define (view) (layout:selected-view))

(define (datums b) (document:datums (buffers:document b)))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))

(define (menu-buffer) (buffers:find " *transient*"))

(define (menu)
  (define (attribute d key) (let ([p (assq key (vector-ref d 1))]) (and p (cdr p))))
  (define (entry d)
    (let ([argument (attribute d 'argument)])
      (append (list (attribute d 'key) (attribute d 'description))
              (if argument (list (if (eq? (attribute d 'in) #t) (string-append "*" argument) argument)) '()))))
  (map (lambda (part)
         (if (vector? part)
             (attribute part 'text)
             (map (lambda (d) (if (eq? (vector-ref d 0) 'transient:%heading) (attribute d 'text) (entry d)))
                  (cddr part))))
       (cddr (car (datums (menu-buffer))))))

(define (popup)
  (let ([vs (views:showing (menu-buffer))])
    (and (pair? vs) (car vs))))

(define (popups) (car (datums layout:popups-buffer)))

(define (html v) (html->string (views:draw v client)))

(define (search text needle from)
  (let ([n (string-length needle)])
    (let loop ([i from])
      (cond
        [(> (+ i n) (string-length text)) #f]
        [(string=? (substring text i (+ i n)) needle) i]
        [else (loop (+ i 1))]))))

(define (between s open close)
  (let ([i (search s open 0)])
    (and i (substring s i (+ (search s close i) (string-length close))))))

(define (entry-at key)
  (let ([doc (buffers:document (menu-buffer))])
    (let loop ([p 0])
      (and (< p (document:length doc))
           (let ([t (document:token doc p)])
             (if (and (document:node? t) (document:atom? t) (equal? (document:node-attribute t 'key) key))
                 p
                 (loop (+ p 1))))))))

(define (mouse-in! c v action place)
  (parameterize ([web:current-client c])
    ((table-ref web:input-handlers "mouse") c
     (append place
             `(("type" . "mouse") ("action" . ,action) ("button" . 1) ("clicks" . 1) ("modifiers" . #())
               ("view" . ,(views:id v)) ("version" . ,(buffers:version (views:buffer v)))
               ("showing" . ,(views:shown-count v)) ("report" . 1))))))

(define (click-token-in! c v at)
  (mouse-in! c v "down" `(("token" . ,at)))
  (mouse-in! c v "click" `(("token" . ,at))))

(define (click-entry-in! c key) (click-token-in! c (popup) (entry-at key)))

(define (click-entry! key) (click-entry-in! client key))

(import (console))
