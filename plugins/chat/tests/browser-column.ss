(import (tuna) (test) (test-browser) (cdp page) (design-tokens) (views) (chat) (chat-test fake-talks) (chat-test fake-agents) (chat-test))

(define page (test-browser:open (page-options [width 1600] [height 900] [color-scheme (color-scheme light)])))

(define e (chat-test/fake-talks:start 'echo (getenv "HOME")))

(define (box selector) (test-browser:call (lambda () (element-box (car (page-query page selector))))))

(define (right-edge r) (+ (rectangle-x r) (rectangle-width r)))

(test "a chat's text is a column narrower than a wide view, centred in it"
  (chat:show! e)
  (chat-test/fake-talks:reply! e "Hello")
  (test-browser:wait-for-applied page)
  (let* ([in-view (format "[data-view=\"~a\"] .view-lines" (views:id (chat-test:view)))]
         [lines (box in-view)] [column (box (string-append in-view " .chat"))]
         [left (- (rectangle-x column) (rectangle-x lines))] [right (- (right-edge lines) (right-edge column))])
    (check (> left 0))
    (check-compare (lambda (a b) (< (abs (- a b)) 1)) left right)))
