(import (options) (tables))
(import (tuna) (document) (web))
(use-plugin clipboard)
(use-plugin layout)

(define laptop (web:add-client! 1))
(define phone (web:add-client! 2))

(define (press! client . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client client])
        (views:call-with-view (layout:selected-view)
          (lambda () (keys:press! client key)))))
    keys))

(define (view) (layout:selected-view))

(define (text) (document:text (buffers:document (views:buffer (view)))))

(define (start! content point)
  (let ([b (buffers:make (symbol->string (gensym "t")) content)])
    (views:set-buffer! (view) b)
    (views:set-point! (view) point)))

(define (handle! client type . fields)
  (parameterize ([web:current-client client])
    ((tables:ref web:input-handlers type) client (cons (cons "type" type) fields))))
(define (copies)
  (filter (lambda (call) (equal? (cadr call) "copy")) (web:take-page-calls!)))
(import (console))
