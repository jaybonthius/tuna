(import (tuna) (test) (test-user) (timers) (faces) (ask) (minibuffer) (completion) (completion-list) (editing) (completion-test sessions))

(define (quit! r)
  (test-user:press! "C-g")
  (check-raises cancelled? (completion-test/sessions:result r)))

(test "ask:choice offers the choices' labels in their order, and answers with the chosen one's value"
  (let ([r (completion-test/sessions:start! (lambda () (ask:choice "Action: " (list (cons "Rename" 'rename) (cons "Extract method" 'extract) (cons "Inline" 'inline)))))])
    (check-equal? '("Rename" "Extract method" "Inline") (completion-test/sessions:texts (completion-test/sessions:session)))
    (test-user:type! "ext")
    (check-equal? '("Extract method") (completion-test/sessions:texts (completion-test/sessions:session)))
    (test-user:press! "RET")
    (check-equal? 'extract (completion-test/sessions:result r))))

(test "only a choice answers ask:choice; C-g quits it"
  (let ([r (completion-test/sessions:start! (lambda () (ask:choice "Action: " (list (cons "Rename" 'rename)))))])
    (test-user:type! "zz")
    (test-user:press! "RET")
    (check-equal? 'waiting (completion-test/sessions:result r))
    (check-equal? "zz" (completion-test/sessions:input))
    (quit! r)))

(test "an annotated choice's annotation is shown in the shadow face"
  (let ([r (completion-test/sessions:start! (lambda () (ask:choice "Action: " (list (vector "Rename" 'rename "F2") (cons "Inline" 'inline)))))])
    (let ([s (completion-test/sessions:session)])
      (check-equal? (list (list (cons faces:shadow "F2")) '())
        (map (lambda (m) (completion:annotation s m)) (completion-test/sessions:matches s)))
      (check-equal? (list completion:choice-category) (completion:session-categories s)))
    (quit! r)))

(test "ask:line-with-candidates offers its candidates and answers with input that names none"
  (let ([r (completion-test/sessions:start! (lambda () (ask:line-with-candidates "Identifier: " (list "car" "cdr" "cons"))))])
    (check-equal? '("car" "cdr" "cons") (completion-test/sessions:texts (completion-test/sessions:session)))
    (test-user:type! "co")
    (check-equal? '("cons") (completion-test/sessions:texts (completion-test/sessions:session)))
    (test-user:press! "RET")
    (check-equal? "cons" (completion-test/sessions:result r)))
  (let ([r (completion-test/sessions:start! (lambda () (ask:line-with-candidates "Identifier: " (list "car" "cdr"))))])
    (test-user:type! "caddr")
    (test-user:press! "RET")
    (check-equal? "caddr" (completion-test/sessions:result r))))

(test "ask:line-with-candidates' default answers an empty input"
  (let ([r (completion-test/sessions:start! (lambda () (ask:line-with-candidates "Identifier: " (list "car" "cdr") "cdr")))])
    (test-user:press! "RET")
    (check-equal? "cdr" (completion-test/sessions:result r))))

(test "a procedure gives the candidates for each input, may pause, and a newer input quits the task still asking"
  (let* ([asked '()] [quits 0]
         [identifiers (lambda (input)
                        (set! asked (cons input asked))
                        (guard (c [(cancelled? c) (set! quits (+ quits 1)) (raise c)])
                          (timers:sleep (if (string=? input "x") 1 0.01)))
                        (list (string-append input "-one") (string-append input "-two")))]
         [r (completion-test/sessions:start! (lambda () (ask:line-with-candidates "Identifier: " identifiers)))])
    (completion-test/sessions:wait-matches (completion-test/sessions:session))
    (check-equal? '("-one" "-two") (completion-test/sessions:texts (completion-test/sessions:session)))
    (test-user:type! "xy")
    (completion-test/sessions:wait-matches (completion-test/sessions:session))
    (check-equal? '("xy-one" "xy-two") (completion-test/sessions:texts (completion-test/sessions:session)))
    (check-equal? '("" "x" "xy") (reverse asked))
    (check-equal? 1 quits)
    (test-user:press! "C-n RET")
    (check-equal? "xy-two" (completion-test/sessions:result r))))

(test "the procedure's candidates show as it gives them, neither filtered nor sorted again"
  (let ([r (completion-test/sessions:start! (lambda () (ask:line-with-candidates "Identifier: " (lambda (input) (list (string-append "my-" input) (string-append "zz-" input) input)))))])
    (test-user:type! "x")
    (completion-test/sessions:wait-matches (completion-test/sessions:session))
    (check-equal? '("my-x" "zz-x" "x") (completion-test/sessions:texts (completion-test/sessions:session)))
    (test-user:press! "RET")
    (check-equal? "my-x" (completion-test/sessions:result r))))
