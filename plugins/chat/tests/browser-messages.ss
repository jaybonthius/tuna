(import (tuna) (test) (test-browser) (cdp page) (design-tokens) (views) (chat) (chat-test fake-talks) (chat-test fake-agents) (chat-test))

(define page (test-browser:open (page-options [width 1200] [height 600] [color-scheme (color-scheme light)])))

(define e (chat-test/fake-talks:start 'echo (getenv "HOME")))

(define b (chat:buffer e))

(for-each
  (lambda (i)
    (chat-test/fake-talks:add! e 'user (format "Question ~a" i))
    (chat-test/fake-talks:reply! e (apply string-append (map (lambda (j) (format "Line ~a of answer ~a.\n\n" j i)) (iota 6)))))
  (iota 30))

(define (view-selector) (format "[data-view=\"~a\"]" (views:id (chat-test:view))))

;; The message's box holds the view's top edge: its line is the first the
;; view shows, and its padding may sit above it.
(define (on-top? text)
  (test-browser:wait-for-applied page)
  (let ([view (view-selector)] [messages (string-append (view-selector) " .chat-user-message")])
    (test-browser:call
      (lambda ()
        (let ([top (rectangle-y (element-box (car (page-query page view))))]
              [box (element-box (find (lambda (m) (equal? text (element-text m))) (page-query page messages)))])
          (<= (rectangle-y box) top (+ (rectangle-y box) (rectangle-height box))))))))

(test "n and p put your message on the view's top line, from a message above it on screen or below it"
  (chat:show! e)
  (test-browser:wait-for-applied page)
  (chat-test:at! b "Question 3")
  (test-browser:press! page "n")
  (check (on-top? "Question 4"))
  (chat-test:at! b "Line 1 of answer 28")
  (test-browser:wait-for-applied page)
  (test-browser:press! page "p")
  (check (on-top? "Question 28")))
