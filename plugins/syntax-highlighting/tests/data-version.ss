(import (tuna) (test) (test-runner) (modes) (buffers) (syntax-highlighting) (buffers-test) (syntax-highlighting-test marks))

(define c (buffers:make "c.mk" "#a b"))

(define (data-version) (syntax-highlighting:data-version c))

(test "data-version is #f until the job returns data, then the version the job read for it, which the input procedure sees with the data"
  (modes:set-major-mode syntax-highlighting-test/marks:counting c)
  (check-equal? #f (data-version))
  (test-runner:wait-until (lambda () (eqv? (buffers:version c) (data-version))))
  (check-equal? (list (list #f #f) (list 1 (buffers:version c))) (syntax-highlighting-test/marks:counted)))

(test "data equal to the last moves data-version on without calling the input procedure; new data calls it with its version"
  (buffers:insert! c 4 "x")
  (test-runner:wait-until (lambda () (eqv? (buffers:version c) (data-version))))
  (check-equal? '() (syntax-highlighting-test/marks:counted))
  (buffers:insert! c 4 "#")
  (test-runner:wait-until (lambda () (eqv? (buffers:version c) (data-version))))
  (check-equal? (list (list 2 (buffers:version c))) (syntax-highlighting-test/marks:counted)))

(test "a buffer with no job has no data-version, and anything but a buffer raises"
  (check-equal? #f (syntax-highlighting:data-version (buffers:make "plain" "#a")))
  (check-raises (buffers-test:raised-with? 'syntax-highlighting:data-version "not a buffer" '(c))
                (syntax-highlighting:data-version 'c)))
