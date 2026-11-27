#!tuna
(import (layout) (views) (buffers) (document) (search) (replace) (test-user) (isearch-test))

(define (text)
  (let ([doc (buffers:document (views:buffer (layout:selected-view)))])
    (buffers:text-between doc 0 (document:length doc))))

(define session
  (case-lambda
    [() (session (test-user:client))]
    [(client) (replace:current client)]))

(define (asked)
  (let* ([s (session)] [m (and s (replace:session-match s))])
    (list (isearch-test:point) (isearch-test:prompt)
          (and m (buffers:text-between (buffers:document (views:buffer (replace:session-view s))) (search:match-start m) (search:match-end m))))))

(define replace!
  (case-lambda
    [(keys from)
     (test-user:press! keys)
     (test-user:type! from)
     (test-user:press! "RET")]
    [(keys from to)
     (replace! keys from)
     (test-user:type! to)
     (test-user:press! "RET")]))

(define (raised thunk)
  (guard (c [(and (who-condition? c) (message-condition? c))
             (list (condition-who c) (condition-message c) (if (irritants-condition? c) (condition-irritants c) '()))])
    (thunk)
    'none))
