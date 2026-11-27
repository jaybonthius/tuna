(import (tuna) (test) (scopes))

(define (in-thread thunk)
  (let ([result #f])
    (join-task (fork-task (lambda (restore) (set! result (thunk)))))
    result))

(test "a scope is a scope, and there is no current scope by default"
  (check (scopes:scope? (scopes:make)))
  (check (not (scopes:scope? 'scope)))
  (check-equal? #f (scopes:current)))

(test "scopes:current is a thread parameter that takes only a scope or #f"
  (let ([s (scopes:make)])
    (parameterize ([scopes:current s])
      (check-equal? s (scopes:current))
      (check-equal? s (in-thread scopes:current))
      (check-equal? #f (in-thread (lambda () (parameterize ([scopes:current #f]) (scopes:current)))))
      (check-equal? s (scopes:current)))
    (check-raises assertion-violation? (parameterize ([scopes:current 'not-a-scope]) (scopes:current)))))

(test "a key, the same for a name, holds one kind of local value: #f until set, and #f again means none"
  (let ([s (scopes:make)] [k (scopes:make-key 'scopes-test-k)] [other (scopes:make-key 'scopes-test-other)])
    (check (fixnum? k))
    (check (not (eqv? k other)))
    (check-equal? k (scopes:make-key 'scopes-test-k))
    (check-raises assertion-violation? (scopes:make-key "k"))
    (check-equal? #f (scopes:ref s k))
    (scopes:set! s k 'value)
    (check-equal? 'value (scopes:ref s k))
    (check-equal? #f (scopes:ref s other))
    (check-equal? 'value (in-thread (lambda () (scopes:ref s k))))
    (check (memq s (scopes:holding k)))
    (scopes:set! s k #f)
    (check-equal? #f (scopes:ref s k))
    (check (not (memq s (scopes:holding k))))))

(test "a scope's values go when nothing holds the scope"
  (let ([k (scopes:make-key 'scopes-test-collected)])
    (let loop ([i 0]) (when (< i 100) (scopes:set! (scopes:make) k i) (loop (+ i 1))))
    (collect (collect-maximum-generation))
    (check-equal? '() (scopes:holding k))))
