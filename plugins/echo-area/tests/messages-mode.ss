(import (tuna) (test))

;; A form of its own, so it loads before echo-area.
(import (echo-area-test beneath))

(import (test-user) (layout) (views) (buffers) (document) (keys) (commands) (modes) (ask) (editing)
        (echo-area) (echo-area-test))

(define view echo-area-test:view)

(define log (begin (echo-area:message! "start") (buffers:find "*Messages*")))

(test "*Messages* is in messages-mode, derived from modes:special, with the lighter Messages"
  (check-equal? (list echo-area:messages-mode #t "Messages")
    (list (modes:major-mode log) (modes:derived? echo-area:messages-mode modes:special) (modes:lighter echo-area:messages-mode))))

(test "q quits its view and SPC scrolls, while g and printing keys are undefined"
  (layout:switch-to-buffer log)
  (check-equal? '(layout:quit-view views:scroll-up keys:undefined keys:undefined)
    (map (lambda (key) (views:with-view (view) (commands:command-name (keys:lookup (test-user:client) key)))) '("q" "SPC" "g" "x")))
  (check-equal? '("g is undefined") (map condition-message (echo-area-test:reports-during (lambda () (test-user:press! "g"))))))

(test "a view whose point is at the end of the log follows each new message; one elsewhere stays"
  (ask:message "first")
  (let ([v (view)] [end (lambda () (- (document:length (buffers:document log)) 1))])
    (views:set-point! v (end))
    (ask:message "second")
    (check-equal? (end) (views:point v))
    (views:set-point! v 1)
    (ask:message "third")
    (check-equal? 1 (views:point v))))

(test "q leaves the log"
  (test-user:press! "q")
  (check (not (eq? (views:buffer (view)) log))))
