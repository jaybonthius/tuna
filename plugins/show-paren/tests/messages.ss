(import (tuna) (test) (test-user) (options) (commands) (keys) (buffers) (document) (views) (editing) (show-paren)
        (editing-test scene) (sexp-test scene))

(define (said-after! marked keys)
  (sexp-test/scene:show! marked)
  (editing-test/scene:take-said!)
  (test-user:press! keys)
  (editing-test/scene:take-said!))

(define (scrolled-to-end! marked)
  (let ([b (sexp-test/scene:show! marked)])
    (views:scroll-to! (editing-test/scene:view) (views:point (editing-test/scene:view)) (views:align top))
    (test-user:settle)
    (editing-test/scene:take-said!)
    b))

(define body (apply string-append (map (lambda (i) " x\n") (iota 60))))

(test "typing a closing bracket whose match is above the view's top says the matching line"
  (scrolled-to-end! (string-append "(define (f)\n" body " y|"))
  (test-user:press! ")")
  (check-equal? '("Matches (define (f)") (editing-test/scene:take-said!)))

(test "a closing bracket whose match is in view says nothing"
  (check-equal? '() (said-after! "(a b|" ")")))

(test "a closing bracket of another shape than its opening one says so"
  (check-equal? '("Mismatched brackets") (said-after! "[a b|" ")")))

(test "a closing bracket with no opening one says so"
  (check-equal? '("No matching bracket") (said-after! "a b|" ")")))

(test "with message-on-close off, nothing is said"
  (options:set! show-paren:message-on-close #f)
  (check-equal? '() (said-after! "a b|" ")"))
  (options:unset! show-paren:message-on-close))

(commands:define-command (close-and-pass)
  "Inserts the typed character, as a user's own command for a closing key may."
  (let* ([view (views:current)] [p (views:point view)])
    (buffers:replace! (views:buffer view) p p (string (keys:typed-char)))
    (views:set-point! view (+ p 1))))

(test "the message follows the key typed, whichever command it ran"
  (sexp-test/scene:show! "a b|")
  (keys:bind! keys:global ")" close-and-pass)
  (editing-test/scene:take-said!)
  (test-user:press! ")")
  (keys:unbind! keys:global ")")
  (check-equal? '("No matching bracket") (editing-test/scene:take-said!)))
