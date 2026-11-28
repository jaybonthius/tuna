(import (tuna) (test) (test-runner) (test-user) (saved) (minibuffer) (completion) (completion-list) (editing) (completion-test sessions) (minibuffer-test reading))

(saved:define-saved h '() list?)

(test "M-r reads an entry of the prompt's history with a nested read that starts from the input; RET puts it in the input"
  (saved:set! h '("gamma" "beta" "alpha"))
  (let ([r (minibuffer-test/reading:start! (lambda () (minibuffer:read "Word: " h)))])
    (test-user:type! "be")
    (test-user:press! "M-r")
    (check-equal? '("beta") (completion-test/sessions:texts (completion-test/sessions:session)))
    (check-equal? "be" (minibuffer-test/reading:input))
    (check-equal? #f (minibuffer:prompt-history (minibuffer-test/reading:prompt)))
    (test-user:press! "RET")
    (check-equal? "beta" (minibuffer-test/reading:input))
    (test-user:press! "RET")
    (check-equal? "beta" (minibuffer-test/reading:result r))
    (check-equal? '("beta" "gamma" "alpha") (h))))

(test "M-s lists the history newest first, and the entry chosen becomes the outer read's input"
  (saved:set! h '("beta" "gamma" "alpha"))
  (let ([r (minibuffer-test/reading:start! (lambda () (completion:read "Word: " (list (completion:source (candidates (vector "one" "two" "gamma")))) h)))])
    (test-user:press! "M-s")
    (check-equal? '("beta" "gamma" "alpha") (completion-test/sessions:texts (completion-test/sessions:session)))
    (test-user:press! "C-n RET")
    (check-equal? 'waiting (minibuffer-test/reading:result r))
    (check-equal? "gamma" (minibuffer-test/reading:input))
    (check-equal? '("gamma") (completion-test/sessions:texts (completion-test/sessions:session)))
    (test-user:press! "RET")
    (check-equal? "gamma" (minibuffer-test/reading:result r))))

(test "a read-entry prompt's own entries come first, and one chosen is given as chosen, as M-p gives it"
  (saved:set! h '("beta" "gamma" "alpha"))
  (let ([r (minibuffer-test/reading:start! (lambda () (call-with-values (lambda () (minibuffer:read-entry "Word: " h '("one" "two"))) list)))])
    (test-user:press! "M-r")
    (check-equal? '("one" "two" "beta" "gamma" "alpha") (completion-test/sessions:texts (completion-test/sessions:session)))
    (test-user:type! "tw")
    (test-user:press! "RET")
    (check-equal? "two" (minibuffer-test/reading:input))
    (test-user:press! "RET")
    (check-equal? '("two" 1) (minibuffer-test/reading:result r))))

(test "M-r on a prompt with no history raises History is empty, and the read waits"
  (let ([r (minibuffer-test/reading:start! (lambda () (minibuffer:read "Word: " #f)))])
    (let ([reported (test-runner:reports-during (lambda () (test-user:press! "M-r")))])
      (check-equal? '((completion:search-history "History is empty"))
        (map (lambda (c) (list (condition-who c) (condition-message c))) reported)))
    (check-equal? 'waiting (minibuffer-test/reading:result r))
    (test-user:press! "C-g")
    (check-raises cancelled? (minibuffer-test/reading:result r))))
