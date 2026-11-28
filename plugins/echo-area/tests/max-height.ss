(import (tuna) (test))

;; A form of its own, so it loads before echo-area.
(import (echo-area-test beneath))

(import (test-user) (test-runner) (options) (keys) (echo-area) (echo-area-test))

(define (style) (test-user:element-attribute (echo-area-test:element) "style"))

(define (rejected? c) (and (assertion-violation? c) (who-condition? c)))

(test "the echo area's message carries echo-area:max-height, a quarter of the page by default, as a custom property"
  (check-equal? 0.25 (echo-area:max-height))
  (echo-area:message! "Hello")
  (test-user:settle)
  (check-equal? "--echo-area-max-height:calc(0.25 * 100dvh)" (style)))

(test "an exact count is lines; an inexact fraction of 1.0 is the whole page"
  (options:set! echo-area:max-height 3)
  (test-user:settle)
  (check-equal? "--echo-area-max-height:3lh" (style))
  (options:set! echo-area:max-height 1.0)
  (test-user:settle)
  (check-equal? "--echo-area-max-height:calc(1.0 * 100dvh)" (style)))

(test "a client's keys in progress carry it too"
  (options:set! echo-area:max-height 2 echo-area:echo-keystrokes 0.05)
  (test-user:press! "C-x")
  (test-runner:wait-until (lambda () (echo-area-test:echo-element (test-user:client))))
  (check-equal? "--echo-area-max-height:2lh" (style))
  (echo-area-test:reports-during (lambda () (test-user:press! "C-g")))
  (options:unset! echo-area:echo-keystrokes))

(test "echo-area:max-height takes only an inexact fraction in (0, 1] or an exact positive count"
  (for-each
    (lambda (v) (check-raises rejected? (options:set! echo-area:max-height v)))
    (list 0 -1 0.0 1.5 1/2 'quarter))
  (options:unset! echo-area:max-height))
