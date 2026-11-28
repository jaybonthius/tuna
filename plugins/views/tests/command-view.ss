(import (tuna) (test) (test-user) (commands) (layout) (buffers) (views) (kill-ring))

(define (raised? who text)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c)) (message-condition? c) (string=? text (condition-message c)))))

(commands:define-command (name-view)
  "Puts the name of the buffer of the view the command runs in on the kill ring."
  (kill-ring:push! (list (buffers:name (views:buffer (views:command-view 'name-view))))))

(test "command-view gives the view a command runs in"
  (test-user:show! "ab|c")
  (views:with-view (layout:selected-view) (commands:run name-view))
  (check-equal? (buffers:name (views:buffer (layout:selected-view))) (kill-ring:text (kill-ring:current))))

(test "command-view outside any view raises naming the caller, and checks its argument"
  (check-raises (raised? 'caller "no view is current") (views:command-view 'caller))
  (check-raises (raised? 'views:command-view "not a symbol") (views:command-view "caller")))
