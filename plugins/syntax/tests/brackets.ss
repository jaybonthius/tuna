(import (tuna) (test) (test-runner) (test-user) (modes) (buffers) (tables) (syntax) (syntax-highlighting) (chez-scheme)
        (chez-scheme-test scheme-buffers))

(define (brackets-become b expected)
  (test-runner:wait-until (lambda () (equal? expected (chez-scheme-test/scheme-buffers:brackets b)))))

(define k (chez-scheme-test/scheme-buffers:scheme-buffer "k.ss" "(a [b) #vu8(1) \"(\" ; )\n))"))

(test "a buffer has bracket spans only while a plugin in syntax:bracket-users draws them"
  (check-equal? #f (syntax:brackets-used? k))
  (test-user:settle)
  (check-equal? '() (chez-scheme-test/scheme-buffers:brackets k))
  (tables:set! syntax:bracket-users 'test (lambda (buffer) (eq? buffer k)))
  (check-equal? #t (syntax:brackets-used? k))
  (syntax-highlighting:update!)
  (brackets-become k '((1 2 ((bracket . 1))) (4 5 ((bracket . 2))) (6 7 ((bracket . mismatched))) (8 13 ((bracket . 2)))
                       (14 15 ((bracket . 2))) (24 25 ((bracket . 1))) (25 26 ((bracket . unmatched)))))
  (tables:remove! syntax:bracket-users 'test)
  (syntax-highlighting:update!)
  (brackets-become k '()))

(test "the bracket layer is below the highlights' layer, so a bracket span is drawn inside a highlight span"
  (tables:set! syntax:bracket-users 'test (lambda (buffer) (eq? buffer k)))
  (syntax-highlighting:update!)
  (test-runner:wait-until (lambda () (pair? (chez-scheme-test/scheme-buffers:brackets k))))
  (check-equal? (list syntax-highlighting:faces syntax:brackets)
                (filter (lambda (t) (memq t (list syntax-highlighting:faces syntax:brackets)))
                        (map (lambda (layer) (cond [(eq? layer (buffers:layer k syntax:brackets)) syntax:brackets]
                                                   [(eq? layer (buffers:layer k syntax-highlighting:faces)) syntax-highlighting:faces]
                                                   [else #f]))
                             (buffers:layers k))))
  (tables:remove! syntax:bracket-users 'test))
