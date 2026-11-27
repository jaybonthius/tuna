#!tuna
(import (layout) (buffers) (document) (views) (web) (test-user))

(define (tree) (car (document:datums (buffers:document layout:buffer))))

(define (set-parts! part)
  (let ([n (document:length (buffers:document layout:buffer))])
    (buffers:replace! layout:buffer 1 (- n 1) (document:from-datum part))
    (void)))

(define (atom view . attributes)
  (views:view (cons* (cons 'view (views:id view)) (cons 'buffer (buffers:name (views:buffer view))) attributes)))

(define (name-of view) (buffers:name (views:buffer view)))

;; An atom keeps the buffer name it was made with, so the outline names
;; the buffer its view shows now.
(define (outline-of d)
  (if (vector? d)
      (let ([v (views:find (cdr (assq 'view (vector-ref d 1))))])
        (if v (name-of v) (cdr (assq 'buffer (vector-ref d 1)))))
      (cons (car d) (map outline-of (cddr d)))))

(define (outline) (outline-of (tree)))

(define (tabs-children)
  (let* ([doc (buffers:document layout:buffer)] [tabs (document:token doc 1)] [acc '()])
    (document:for-each-child tabs (+ (document:node-start tabs) 1) (- (document:node-end tabs) 1)
      (lambda (c at) (when (document:node? c) (set! acc (cons c acc)))))
    (reverse acc)))

;; The page sends a marked keymap's number, before its state.
(define (mark-number keymap) (read (open-input-string (views:keymap-mark keymap))))

(define mouse!
  (case-lambda
    [(keymaps button at) (mouse! keymaps button at (buffers:version layout:buffer) '("down" "click"))]
    [(keymaps button at version actions)
     (let ([s layout:screen-view] [client (test-user:client)])
       (for-each
         (lambda (action)
           (web:post-input! client
             (append
               (list (cons "type" "mouse") (cons "action" action) (cons "button" button) (cons "clicks" 1)
                     (cons "modifiers" '#()) (cons "token" at) (cons "view" (views:id s)) (cons "version" version)
                     (cons "showing" (views:shown-count s)))
               (if (null? keymaps) '() (list (cons "keymaps" (list->vector (map mark-number keymaps))))))))
         actions)
       (test-user:settle))]))

(define (raised-with who message)
  (lambda (e)
    (and (who-condition? e) (eq? who (condition-who e))
         (message-condition? e) (string=? message (condition-message e)))))

(define (refusals-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    (map (lambda (c) (list (and (who-condition? c) (condition-who c)) (condition-message c))) (reverse reported))))
