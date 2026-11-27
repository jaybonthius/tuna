(import (tuna) (test) (test-user) (saved) (minibuffer) (completion) (completion-list) (editing) (sessions))

(saved:define-saved h '() list?)

(test "M-r reads an entry of the prompt's history with a nested read that starts from the input; RET puts it in the input"
  (saved:set! h '("gamma" "beta" "alpha"))
  (let ([r (sessions:start! (lambda () (minibuffer:read "Word: " h)))])
    (test-user:type! "be")
    (test-user:press! "M-r")
    (check-equal? '("beta") (sessions:texts (sessions:session)))
    (check-equal? "be" (sessions:input))
    (check-equal? #f (minibuffer:prompt-history (sessions:prompt)))
    (test-user:press! "RET")
    (check-equal? "beta" (sessions:input))
    (test-user:press! "RET")
    (check-equal? "beta" (sessions:result r))
    (check-equal? '("beta" "gamma" "alpha") (h))))

(test "M-s lists the history newest first, and the entry chosen becomes the outer read's input"
  (saved:set! h '("beta" "gamma" "alpha"))
  (let ([r (sessions:start! (lambda () (completion:read "Word: " (list (completion:source (candidates (vector "one" "two" "gamma")))) h)))])
    (test-user:press! "M-s")
    (check-equal? '("beta" "gamma" "alpha") (sessions:texts (sessions:session)))
    (test-user:press! "C-n RET")
    (check-equal? 'waiting (sessions:result r))
    (check-equal? "gamma" (sessions:input))
    (check-equal? '("gamma") (sessions:texts (sessions:session)))
    (test-user:press! "RET")
    (check-equal? "gamma" (sessions:result r))))

(test "a read-entry prompt's own entries come first, and one chosen is given as chosen, as M-p gives it"
  (saved:set! h '("beta" "gamma" "alpha"))
  (let ([r (sessions:start! (lambda () (call-with-values (lambda () (minibuffer:read-entry "Word: " h '("one" "two"))) list)))])
    (test-user:press! "M-r")
    (check-equal? '("one" "two" "beta" "gamma" "alpha") (sessions:texts (sessions:session)))
    (test-user:type! "tw")
    (test-user:press! "RET")
    (check-equal? "two" (sessions:input))
    (test-user:press! "RET")
    (check-equal? '("two" 1) (sessions:result r))))

(test "M-r on a prompt with no history raises History is empty, and the read waits"
  (let ([r (sessions:start! (lambda () (minibuffer:read "Word: " #f)))])
    (let ([reported (sessions:reports-during (lambda () (test-user:press! "M-r")))])
      (check-equal? '((completion:search-history "History is empty"))
        (map (lambda (c) (list (condition-who c) (condition-message c))) reported)))
    (check-equal? 'waiting (sessions:result r))
    (test-user:press! "C-g")
    (check-raises cancelled? (sessions:result r))))
