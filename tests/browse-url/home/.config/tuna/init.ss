(import (tables))
(import (tuna) (web) (buffers) (document))
(use-plugin buffers)
(use-plugin browse-url)

(define laptop (web:add-client! 1))
(define phone (web:add-client! 2))

(define (handle! client type . fields)
  (parameterize ([web:current-client client])
    ((tables:ref web:input-handlers type) client (cons (cons "type" type) fields))))
(import (console))
