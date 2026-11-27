#!tuna
(import (buffers) (document) (views) (layout) (web) (test-user) (status-line))

(define (view) (layout:selected-view))

(define (segments footer)
  (map (lambda (e) (cons (test-user:element-attribute e "data-segment") (test-user:element-text e)))
       (test-user:elements footer "status-line-segment")))

(define (footers-in element) (test-user:elements element "status-line"))

(define status-lines
  (case-lambda
    [() (status-lines (test-user:client))]
    [(client)
     (test-user:settle)
     (map segments (footers-in (test-user:screen client)))]))

(define (%window-element client window)
  (let ([at (number->string (document:node-start (layout:view-node window)))])
    (find (lambda (e) (equal? at (test-user:element-attribute e "data-at")))
          (test-user:elements (test-user:screen client) "layout-view"))))

(define (footer window)
  (test-user:settle)
  (let ([e (%window-element (test-user:client) window)])
    (and e (let ([fs (footers-in e)]) (and (pair? fs) (car fs))))))

(define (status window)
  (let ([f (footer window)])
    (and f (segments f))))

(define (segment-names window) (map car (status window)))

(define (segment-text window name)
  (let ([s (assoc (if (symbol? name) (symbol->string name) name) (status window))])
    (and s (cdr s))))

;; The page sends a marked keymap's number, before its state.
(define (mark-number keymap) (read (open-input-string (views:keymap-mark keymap))))

(define (mouse-item window action button version keymaps)
  (list (cons "type" "mouse") (cons "action" action) (cons "button" button) (cons "clicks" 1)
        (cons "modifiers" '#()) (cons "token" (document:node-start (layout:view-node window)))
        (cons "view" (views:id layout:screen-view)) (cons "version" version)
        (cons "showing" (views:shown-count layout:screen-view))
        (cons "keymaps" (list->vector (map mark-number keymaps)))))

;; The page sends the keymaps of the segment clicked, if any, before the
;; line's.
(define (click! window button . segment-keymaps)
  (let ([version (buffers:version layout:buffer)] [client (test-user:client)])
    (for-each
      (lambda (action)
        (web:post-input! client (mouse-item window action button version (append segment-keymaps (list status-line:keymap)))))
      '("down" "click"))
    (test-user:settle)))

(define (reports-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    (reverse reported)))

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))
