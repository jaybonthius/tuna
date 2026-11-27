(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (keys) (buffers) (views) (layout) (web) (editing) (undo)
        (jump-history) (search) (isearch) (replace) (isearch-test) (replace-test))

(define asked replace-test:asked)

(define text replace-test:text)

(define (at! p) (views:set-point! (isearch-test:view) p))

(define (prompt-for from to) (string-append "Query replacing " from " with " to ": (? for help) "))

(define (starts-with? prefix s) (and (>= (string-length s) (string-length prefix)) (string=? prefix (substring s 0 (string-length prefix)))))

(buffers:define-layer locked (read-only) (sticky before))

(define (chip-text node) "foo")

(buffers:define-kind chip (content atom) (text chip-text))

(test "a match the buffer refuses to edit ends the session with the refusal's message"
  (let ([b (isearch-test:show! "ro" "x1 x2 x3\n")])
    (buffers:add-span! (buffers:layer b locked) 4 6 'locked)
    (replace-test:replace! "M-%" "x" "y")
    (isearch-test:take-said!)
    (test-user:press! "y y")
    (check-equal? '(#f "y1 x2 x3\n" ("a read-only span refuses the edit")) (list (replace-test:session) (text) (isearch-test:take-said!)))
    (at! 1)
    (isearch-test:with-setting replace:skip-read-only #t
      (lambda ()
        (replace-test:replace! "M-%" "x" "y")
        (test-user:press! "!")
        (check-equal? '(#f "y1 x2 y3\n") (list (replace-test:session) (text)))
        (check (starts-with? "Replaced 1 occurrence (skipped 1" (car (isearch-test:take-said!))))))))

(test "a match touching an atom's text is passed over and counted"
  (let ([a (buffers:make "atoms" (buffers:text '() "foo " (chip '()) " foo\n"))])
    (layout:switch-to-buffer a)
    (at! 1)
    (replace-test:replace! "M-%" "foo" "bar")
    (test-user:press! "!")
    (check-equal? "bar foo bar\n" (text))
    (check (starts-with? "Replaced 2 occurrences (skipped 1" (car (isearch-test:take-said!))))))

(test "C-r pauses the session so keys edit as usual, and C-M-c goes on from the current match; C-w deletes the match first"
  (isearch-test:show! "p" "x1 x2 x3\n")
  (replace-test:replace! "M-%" "x" "y")
  (test-user:press! "C-r")
  (check-equal? "Editing; C-M-c goes on with the replace" (keys:prompt (test-user:client)))
  (test-user:press! "C-e Z")
  (check-equal? "x1 x2 x3Z\n" (text))
  (test-user:press! "C-M-c")
  (check-equal? (list 2 (prompt-for "x" "y") "x") (asked))
  (test-user:press! "C-w")
  (check-equal? "1 x2 x3Z\n" (text))
  (test-user:press! "Q C-M-c")
  (check-equal? (list 5 (prompt-for "x" "y") "x") (asked))
  (test-user:press! "!")
  (check-equal? '("Q1 y2 y3Z\n" #f) (list (text) (replace-test:session)))
  (isearch-test:take-said!))

(test "a session is a record with hooks, and advice on replace:prompt changes the prompt"
  (let* ([events '()]
         [started (lambda (s) (set! events (cons (list 'started (replace:session-count s)) events)))]
         [updated (lambda (s) (set! events (cons '(updated) events)))]
         [ended (lambda (s n) (set! events (cons (list 'ended n (keys:prompt (test-user:client))) events)))]
         [with-count (lambda (prompt s)
                       (let* ([scan (replace:session-scan s)] [m (replace:session-match s)]
                              [index (and m (search:scan-index scan (search:match-start m)))])
                         (if (and index (search:scan-done? scan))
                             (cons (format "[~a/~a] " (+ index 1) (search:scan-count scan)) (prompt s))
                             (prompt s))))])
    (hooks:add! replace:started started)
    (hooks:add! replace:updated updated)
    (hooks:add! replace:ended ended)
    (advice-add! replace:prompt with-count)
    (isearch-test:show! "rec" "o1 o2 o3\n")
    (replace-test:replace! "M-%" "o" "0")
    (test-runner:wait-until (lambda () (search:scan-done? (replace:session-scan (replace-test:session)))))
    (test-user:press! "n")
    (check-equal? (string-append "[2/3] " (prompt-for "o" "0")) (isearch-test:prompt))
    (let ([s (replace-test:session)])
      (check (replace:session? s))
      (check-equal? (list (isearch-test:view) (test-user:client) "0" "o")
                    (list (replace:session-view s) (replace:session-client s) (replace:session-replacement s)
                          (search:query-text (replace:session-query s)))))
    (test-user:press! "y q")
    (check-equal? '((started 0) (ended 1 #f)) (filter (lambda (e) (not (equal? e '(updated)))) (reverse events)))
    (check (member '(updated) events))
    (advice-remove! replace:prompt with-count)
    (hooks:remove! replace:started started)
    (hooks:remove! replace:updated updated)
    (hooks:remove! replace:ended ended)
    (isearch-test:take-said!)))

(test "query-replace! answers from the given client's keys, pauses its task until the session ends and returns the count; a procedure replacement gets each match and the count"
  (let ([other (test-user:open-client)] [result #f])
    (isearch-test:show! "code" "k k k\n")
    (let ([t (spawn-task (lambda (restore)
                           (set! result (replace:query-replace! (isearch-test:view) other (search:make-query "k")
                                                                (lambda (m n) (number->string n)) 1 6 (search:direction forward)))))])
      (test-user:settle)
      (check-equal? '(#f #t) (list (replace:current (test-user:client)) (replace:session? (replace:current other))))
      (test-user:press! other "y y q")
      (test-runner:wait-until (lambda () (eq? (task-state t) 'done)))
      (check-equal? '(2 "0 1 k\n") (list result (text))))
    (spawn-task (lambda (restore) (replace:query-replace! (isearch-test:view) other (search:make-query "k") "z" 1 6 (search:direction forward))))
    (test-user:settle)
    (check-equal? '(replace:query-replace! "a replace session is already running for this client")
                  (list-head (replace-test:raised
                               (lambda () (replace:query-replace! (isearch-test:view) other (search:make-query "k") "z" 1 6 (search:direction forward))))
                             2))
    (test-user:press! other "q")
    (web:close-client! other)
    (isearch-test:take-said!)))

(test "! is one command, so its replacements are one undo group"
  (isearch-test:show! "g" "a a a a\n")
  (replace-test:replace! "M-%" "a" "b")
  (test-user:press! "y !")
  (check-equal? "b b b b\n" (text))
  (test-user:press! "C-/")
  (check-equal? "b a a a\n" (text))
  (test-user:press! "C-/")
  (check-equal? "a a a a\n" (text))
  (isearch-test:take-said!))

(test "a session ending away from where it started records that place, and M-, returns there; a quit records too; one with no match nothing"
  (let ([j (isearch-test:show! "j" "w1 w2 w3\n")] [before (length (jump-history:places))])
    (replace-test:replace! "M-%" "q" "v")
    (check-equal? before (length (jump-history:places)))
    (replace-test:replace! "M-%" "w" "v")
    (check (isearch-test:cancelling! "C-g"))
    (check-equal? (list 2 (+ before 1)) (list (isearch-test:point) (length (jump-history:places))))
    (at! 1)
    (replace-test:replace! "M-%" "w" "v")
    (test-user:press! "n y q")
    (check-equal? (list 8 (cons j 1)) (list (isearch-test:point) (car (jump-history:places))))
    (test-user:press! "M-,")
    (check-equal? 1 (isearch-test:point))
    (isearch-test:take-said!)))

(test "M-% during a forward search replaces the search's query from its current match's start; C-M-% takes its text as a regexp"
  (isearch-test:show! "is" "Ab ab AB a.b\n")
  (test-user:press! "C-s a b C-s M-%")
  (test-user:type! "X")
  (test-user:press! "RET")
  (check-equal? (list #f (list 6 (prompt-for "ab" "X") "ab")) (list (isearch:current (test-user:client)) (asked)))
  (test-user:press! "!")
  (check-equal? "Ab X X a.b\n" (text))
  (isearch-test:show! "is2" "a.b axb\n")
  (test-user:press! "C-s a . b C-M-%")
  (test-user:type! "Y")
  (test-user:press! "RET !")
  (check-equal? "Y Y\n" (text))
  (isearch-test:take-said!))

(test "replace-string and replace-regexp replace every match from point without asking"
  (isearch-test:show! "rs" "one one\n")
  (views:with-view (isearch-test:view) (replace:replace-string "one" "two"))
  (check-equal? '("two two\n" ("Replaced 2 occurrences")) (list (text) (isearch-test:take-said!)))
  (isearch-test:show! "rr" "a1 b22\n")
  (views:with-view (isearch-test:view) (replace:replace-regexp "[0-9]+" "<\\&>"))
  (check-equal? '("a<1> b<22>\n" ("Replaced 2 occurrences")) (list (text) (isearch-test:take-said!))))
