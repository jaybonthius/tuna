(import (tuna) (test))

;; A form of its own, so it loads before echo-area.
(import (echo-area-test beneath))

(import (test-user) (tables) (keys) (commands) (editing) (echo-area) (echo-area-test))

(define echo echo-area-test:echo)
(define client (test-user:client))

(tables:define-table pick-keymap)

(commands:define-command (pick) "Stays." (void))

(keys:bind! pick-keymap "p" pick)

(define (push! prompt) (keys:push-keymap! client pick-keymap (lambda (found command) (eq? found pick-keymap)) void prompt))

(define other (test-user:open-client))

(test "a temporary keymap's prompt shows as the client's keys while the keymap is up, on that client only; a key it takes shows through it"
  (let* ([ended '()] [end-pick (keys:push-keymap! client pick-keymap (lambda (found command) (eq? found pick-keymap))
                                 (lambda () (set! ended (cons 'pick ended))) "Pick: ")])
    (test-user:settle)
    (check-equal? '("Pick: " #f) (list (echo) (echo other)))
    (test-user:press! "p")
    (check-equal? "Pick: " (echo))
    (check-equal? '("Pick: ") (echo-area-test:prompt-parts client))
    (end-pick)
    (test-user:settle)
    (check-equal? '((pick) #f) (list ended (echo)))))

(define typed "fo")

(test "a procedure gives the prompt each time it is drawn, and a pair of a face, or #f, and a string is shown text outside the prompt look"
  (let ([end-search (push! (lambda () (list "Failing I-search: " (cons #f typed) (cons 'isearch.fail "x"))))])
    (test-user:settle)
    (check-equal? '("Failing I-search: ") (echo-area-test:prompt-parts client))
    (check-equal? '(("isearch.fail" "x")) (echo-area-test:faced client))
    (check-equal? "Failing I-search: fox" (echo))
    (set! typed "foo")
    (test-user:settle)
    (check-equal? "Failing I-search: foox" (echo))
    (end-search)))

(test "a message covers the prompt, and a key that leaves the keymap ends it, leaving no copy and logging nothing"
  (let ([before (echo-area-test:messages)] [end (push! (lambda () (list "Failing I-search: " (cons #f "fo"))))])
    (echo-area:message! "Wrapped")
    (test-user:settle)
    (check-equal? "Wrapped" (echo))
    (test-user:press! "x")
    (check-equal? '(#f #f) (list (echo) (keys:prompt client)))
    (check-equal? (string-append before "Wrapped\n") (echo-area-test:messages))
    (end)))

(test "adjacent strings are one prompt part, and a control character shows as ^X in escape-glyph, outside the prompt look, in either part"
  (let* ([shown '("[3/17] " "Query replacing a with b: ")] [end (push! (lambda () shown))])
    (test-user:settle)
    (check-equal? '("[3/17] Query replacing a with b: ") (echo-area-test:prompt-parts client))
    (set! shown '("Query replacing a\nb with c: "))
    (test-user:settle)
    (check-equal? '("Query replacing a" "b with c: ") (echo-area-test:prompt-parts client))
    (check-equal? '(("escape-glyph" "^J")) (echo-area-test:faced client))
    (set! shown '("Find: " (#f . "a\tb") (isearch.fail . "c\x7f;")))
    (test-user:settle)
    (check-equal? '("Find: ") (echo-area-test:prompt-parts client))
    (check-equal? '(("escape-glyph" "^I") ("isearch.fail" "c^?") ("escape-glyph" "^?")) (echo-area-test:faced client))
    (check-equal? "Find: a^Ibc^?" (echo))
    (end)))

(test "a fixed list is a prompt too"
  (let ([end (push! (list (cons #f "Repeat with p")))])
    (test-user:settle)
    (check-equal? "Repeat with p" (echo))
    (end)))

(test "a prompt procedure that raises, or returns what is not a prompt, is reported, and no prompt shows"
  (let* ([bad (lambda () (car '()))] [end #f])
    (check-equal? '(car)
      (map condition-who (echo-area-test:reports-during (lambda () (set! end (push! (lambda () (bad)))) (test-user:settle)))))
    (check-equal? "() is not a pair" (echo))
    (check-equal? (make-list 3 '(keys:push-keymap! "a prompt procedure returned what is not a prompt or #f"))
      (map (lambda (value)
             (set! bad (lambda () value))
             (echo-area:message! "")
             (let ([reported (echo-area-test:reports-during test-user:settle)])
               (test-user:settle)
               (check-equal? #f (echo-area-test:echo-element client))
               (list (condition-who (car reported)) (condition-message (car reported)))))
           (list '((3 . "fo")) '(("fo" . #f)) '())))
    (end)))

(test "push-keymap! refuses a prompt that is not a prompt, a procedure or #f"
  (check-equal? (make-list 3 "not a prompt, a procedure or #f")
    (map (lambda (bad) (guard (c [(assertion-violation? c) (condition-message c)]) (push! bad)))
         (list '() '("not" ("allowed" . #f)) 'x))))
