#!tuna
(import (web) (views) (layout) (commands) (editing) (kill-ring) (hooks) (tables))

(define %pasted #f)

(define (paste client item)
  (let ([text (cdr (assoc "text" item))])
    (set! %pasted text)
    (views:call-with-view (layout:selected-view)
      (lambda () (commands:run editing:paste text)))))

(define (copy entry)
  (let ([text (kill-ring:text entry)])
    (unless (equal? text %pasted)
      (for-each (lambda (client) (web:call-page! client "copy" text))
                (web:clients)))))

(tables:set! web:scripts 'clipboard "clipboard.js")
(tables:set! web:input-handlers "paste" paste)
(hooks:add! kill-ring:after-push copy)
