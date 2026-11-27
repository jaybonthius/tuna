#!tuna
(import (layout) (layout-split) (buffers) (document) (views) (web) (keys) (test-user))

(define (tree) (car (document:datums (buffers:document layout:buffer))))

(define (set-parts! part)
  (let ([n (document:length (buffers:document layout:buffer))])
    (buffers:replace! layout:buffer 1 (- n 1) (document:from-datum part))
    (void)))

(define (atom view . attributes)
  (views:view (cons* (cons 'view (views:id view)) (cons 'buffer (buffers:name (views:buffer view))) attributes)))

(define (named name)
  (or (buffers:find name) (buffers:make name (string-append name "\n"))))

(define (view-named name) (views:make (named name)))

(define (name-of view) (buffers:name (views:buffer view)))

;; An atom keeps the buffer name it was made with, so the outline names
;; the buffer its view shows now.
(define (atom-name d)
  (let* ([attributes (vector-ref d 1)] [v (views:find (cdr (assq 'view attributes)))])
    (if v (name-of v) (cdr (assq 'buffer attributes)))))

(define (outline-of d)
  (if (vector? d) (atom-name d) (cons (car d) (map outline-of (cddr d)))))

(define (outline) (outline-of (tree)))

(define (attributes-of view)
  (let find-in ([d (tree)])
    (if (vector? d)
        (and (eqv? (views:id view) (cdr (assq 'view (vector-ref d 1)))) (vector-ref d 1))
        (exists find-in (cddr d)))))

(define (names) (map name-of (layout:views)))

(define (selected-name) (name-of (layout:selected-view)))

(define (order-names) (map name-of (layout:selection-order)))

;; The page sends a marked keymap's number, before its state.
(define (mark-number keymap) (read (open-input-string (views:keymap-mark keymap))))

(define click!
  (case-lambda
    [(at) (click! at 1 '())]
    [(at button keymaps) (click! at button keymaps (buffers:version layout:buffer))]
    [(at button keymaps version)
     (let ([s layout:screen-view] [client (test-user:client)])
       (for-each
         (lambda (action)
           (web:post-input! client
             (append
               (list (cons "type" "mouse") (cons "action" action) (cons "button" button) (cons "clicks" 1)
                     (cons "modifiers" '#()) (cons "token" at) (cons "view" (views:id s)) (cons "version" version)
                     (cons "showing" (views:shown-count s)))
               (if (null? keymaps) '() (list (cons "keymaps" (list->vector (map mark-number keymaps))))))))
         '("down" "click"))
       (test-user:settle))]))

(define (place-echo! b)
  (layout:display-buffer b (layout-split:display-at-side (layout:direction down) 90 'content '((locked . #t)))))

(define (class-names element)
  (let ([value (test-user:element-attribute element "class")])
    (if value
        (let loop ([chars (string->list value)] [word '()] [words '()])
          (let ([add (lambda () (if (null? word) words (cons (list->string (reverse word)) words)))])
            (cond
              [(null? chars) (reverse (add))]
              [(char=? (car chars) #\space) (loop (cdr chars) '() (add))]
              [else (loop (cdr chars) (cons (car chars) word) words)])))
        '())))

(define (has-class? element class) (and (member class (class-names element)) #t))

(define (drawn-views client)
  (map (lambda (e)
         (cons (string->number (test-user:element-attribute (car (test-user:elements e "view")) "data-view"))
               (has-class? e "selected")))
       (test-user:elements (test-user:screen client) "layout-view")))

(define (click-text! view at)
  (let ([client (test-user:client)])
    (for-each
      (lambda (action)
        (web:post-input! client
          (list (cons "type" "mouse") (cons "action" action) (cons "button" 1) (cons "clicks" 1)
                (cons "modifiers" '#()) (cons "at" at) (cons "view" (views:id view))
                (cons "version" (buffers:version (views:buffer view))) (cons "showing" (views:shown-count view)))))
      '("down" "click"))
    (test-user:settle)))

(define (part)
  (let* ([n (layout:selected-part)] [doc (buffers:document layout:buffer)])
    (outline-of (car (document:datums (document:slice doc (document:node-start n) (document:node-end n)))))))

(define (reports-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    (reverse reported)))

(define (refusals-during thunk)
  (map (lambda (c)
         (list (and (who-condition? c) (condition-who c)) (if (message-condition? c) (condition-message c) c)))
       (reports-during thunk)))

(define (raised-with who message)
  (lambda (e)
    (and (who-condition? e) (eq? who (condition-who e))
         (message-condition? e) (string=? message (condition-message e)))))
