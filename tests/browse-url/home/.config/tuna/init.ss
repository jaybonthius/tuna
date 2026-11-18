(import (tuna) (tuna plugins) (web))
(use-plugin browse-url)

(define laptop (web:add-client! 1))
(define phone (web:add-client! 2))

(define (handle! client type . fields)
  (parameterize ([web:current-client client])
    ((table-ref web:input-handlers type) client (cons (cons "type" type) fields))))
(import (console))
