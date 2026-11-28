(import (tuna) (test) (test-browser) (cdp page) (options) (design-tokens) (layout) (layout-split) (editing) (echo-area) (status-line)
        (minibuffer))

(define page (test-browser:open (page-options [width 1200] [height 800])))

(define (style property)
  (test-browser:call (lambda () (element-style (car (page-query page ".echo-area-message")) property))))

(define (pixels text) (string->number (substring text 0 (- (string-length text) 2))))

(echo-area:message! "Hello")

(test-browser:wait-for-applied page)

(test "by default the echo area is at most a quarter of the page high"
  (check-equal? "200px" (style "max-height")))

(test "at 3, it is at most three of its lines high"
  (options:set! echo-area:max-height 3)
  (test-browser:wait-for-applied page)
  (check-equal? (* 3 (pixels (style "line-height"))) (pixels (style "max-height"))))

(test "at 0.5, half the page"
  (options:set! echo-area:max-height 0.5)
  (test-browser:wait-for-applied page)
  (check-equal? "400px" (style "max-height")))
