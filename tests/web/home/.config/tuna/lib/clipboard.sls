#!tuna
(import (web) (views) (layout) (commands) (editing) (kill-ring))

(define pasted #f)

(define (paste client item)
  (let ([text (cdr (assoc "text" item))])
    (set! pasted text)
    (views:call-with-view (layout:selected-view)
      (lambda () (commands:run editing:paste text)))))

(define (copy entry)
  (let ([text (kill-ring:text entry)])
    (unless (equal? text pasted)
      (for-each (lambda (client) (web:call-page! client "copy" text))
                (web:clients)))))

(table-set! web:scripts 'clipboard "clipboard.js")
(table-set! web:input-handlers "paste" paste)
(add-hook! kill-ring:after-push copy)
