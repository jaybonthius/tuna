(import (tuna) (test) (test-user) (test-runner) (hooks) (buffers) (views) (layout) (echo-area) (minibuffer)
        (completion) (completion-list) (completion-popup) (editing) (completion-test sessions))

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

(define (word-start)
  (let* ([v (views:current)] [buffer (views:buffer v)] [p (views:point v)]
         [s (editing:forward-word-position buffer p -1)])
    (and (< s p) (= (editing:forward-word-position buffer s 1) p) s)))

(define exits '())

(define (exit-noting name)
  (lambda (value status) (set! exits (cons (list name value status (test-user:text)) exits))))

(define greek
  (completion:source (candidates (vector "alpha" "alphabet" "alpine" "beta" "unique")) (exit (exit-noting 'greek))))

(define (greek-region)
  (let ([s (word-start)])
    (and s (completion:region s (views:point (views:current)) (list greek)))))

(define (session) (completion-test/sessions:session))

(define (texts) (completion-test/sessions:texts (session)))

(define (start-at-point minimum) (completion-test/sessions:result (completion-test/sessions:start! (lambda () (completion:start-at-point minimum)))))

(define (with-region entry thunk)
  (hooks:add! completion:find-region entry)
  (thunk)
  (when (session) (test-user:press! "C-g"))
  (hooks:remove! completion:find-region entry))

(test "start-at-point starts a session only when the region holds the minimum before point; nothing is selected"
  (with-region greek-region
    (lambda ()
      (test-user:show! "alp|")
      (check-equal? #f (start-at-point 4))
      (check-equal? #f (session))
      (check-equal? #t (start-at-point 3))
      (check-equal? '("alpha" "alpine" "alphabet") (texts))
      (check-equal? #f (completion:selected (session)))
      (check-equal? #f (completion:session-prompt (session))))))

(test "a trigger character right before point starts a session whatever the minimum"
  (with-region
    (lambda ()
      (let ([p (views:point (views:current))])
        (completion:region p p (list greek) (list #\.))))
    (lambda ()
      (test-user:show! "x.|")
      (check-equal? #t (start-at-point 5))
      (check-equal? '("beta" "alpha" "alpine" "unique" "alphabet") (texts)))))

(test "C-M-i after a word that is a match and the start of a longer one opens the session on both"
  (with-region greek-region
    (lambda ()
      (test-user:show! "alpha|")
      (test-user:press! "C-M-i")
      (check-equal? '("alpha" "alphabet") (texts)))))

(test "in the popup the first move selects the first row, since nothing was selected"
  (with-region greek-region
    (lambda ()
      (test-user:show! "alp|")
      (test-user:press! "C-M-i")
      (let ([selected (lambda () (completion-test/sessions:selected-text (session)))])
        (test-user:press! "M-n")
        (check-equal? "alpha" (selected))
        (test-user:press! "M-n")
        (check-equal? "alpine" (selected))
        (test-user:press! "M-p")
        (check-equal? "alpha" (selected))
        (test-user:press! "<down>")
        (check-equal? "alpine" (selected))
        (test-user:press! "M->")
        (check-equal? "alphabet" (selected))
        (test-user:press! "M-<")
        (check-equal? "alpha" (selected))))))

(test "RET with a match selected puts it in place of the word, ends the session and calls its source's exit with finished"
  (set! exits '())
  (with-region greek-region
    (lambda ()
      (test-user:show! "x alp|")
      (test-user:press! "C-M-i M-n M-n RET")
      (check-equal? "x alpine|" (test-user:text))
      (check-equal? #f (session))
      (check-equal? '((greek "alpine" finished "x alpine|")) exits))))

(test "RET with nothing selected types a newline and ends the session, calling no exit"
  (set! exits '())
  (with-region greek-region
    (lambda ()
      (test-user:show! "alp|")
      (test-user:press! "C-M-i RET")
      (check-equal? "alp\n|" (test-user:text))
      (check-equal? #f (session))
      (check-equal? '() exits))))

(test "typing goes on in the session, SPC ends it, and so does moving point out of the region"
  (with-region greek-region
    (lambda ()
      (test-user:show! "al|")
      (test-user:press! "C-M-i")
      (test-user:type! "pi")
      (check-equal? '("alpine") (texts))
      (test-user:press! "C-a")
      (check-equal? #f (session))
      (test-user:press! "C-e C-M-i")
      (check (session))
      (test-user:type! " ")
      (check-equal? #f (session)))))

(test "C-g ends the session and leaves the text, calling no exit"
  (set! exits '())
  (with-region greek-region
    (lambda ()
      (test-user:show! "alp|")
      (test-user:press! "C-M-i M-n C-g")
      (check-equal? #f (session))
      (check-equal? "alp|" (test-user:text))
      (check-equal? '() exits))))

(test "typing what matches nothing hides the session's matches, and DEL brings them back"
  (with-region greek-region
    (lambda ()
      (test-user:show! "alp|")
      (test-user:press! "C-M-i")
      (test-user:type! "z")
      (check (session))
      (check-equal? '() (texts))
      (test-user:press! "DEL")
      (check-equal? '("alpha" "alpine" "alphabet") (texts)))))

(test "TAB with nothing selected puts in the longest common start of the matches, and the session goes on"
  (with-region greek-region
    (lambda ()
      (test-user:show! "alp|")
      (test-user:press! "C-M-i")
      (test-user:type! "h")
      (check-equal? '("alpha" "alphabet") (texts))
      (test-user:press! "TAB")
      (check-equal? "alpha|" (test-user:text))
      (check-equal? '("alpha" "alphabet") (texts)))))

(test "TAB's common start is of the inputs the matches make, each its source's prefix and its text, though the sources split differently"
  (let* ([after-slash (lambda (input)
                        (let loop ([i (string-length input)])
                          (cond [(= i 0) 0] [(char=? (string-ref input (- i 1)) #\/) i] [else (loop (- i 1))])))]
         [two-region (lambda ()
                       (completion:region 1 (views:point (views:current))
                         (list (completion:source (candidates (vector "main.sls" "mainly")) (split after-slash))
                               (completion:source (candidates (vector "lib/maint"))))))])
    (with-region two-region
      (lambda ()
        (test-user:show! "lib/ma|")
        (test-user:press! "C-M-i")
        (check-equal? '("mainly" "main.sls" "lib/maint") (texts))
        (check-equal? #f (completion:selected (session)))
        (test-user:press! "TAB")
        (check-equal? "lib/main|" (test-user:text))
        (check-equal? '("mainly" "main.sls" "lib/maint") (texts))))))

(define tabbed
  (completion:source (candidates (vector "apple" "applet" "apricot")) (split (lambda (input) (min 2 (string-length input))))
    (exit (exit-noting 'tabbed))))

(define (tabbed-region)
  (let* ([v (views:current)] [point (views:point v)] [text (completion-test/sessions:buffer-text (views:buffer v))]
         [start (let loop ([i point]) (if (or (= i 1) (char=? (string-ref text (- i 2)) #\space)) i (loop (- i 1))))])
    (and (< start point) (completion:region start point (list tabbed)))))

(test "TAB on a selected match that keeps a lead before it puts the match in and goes on, calling no exit; RET then calls the chosen one's"
  (set! exits '())
  (with-region tabbed-region
    (lambda ()
      (test-user:show! "x/appl|")
      (test-user:press! "C-M-i M-n TAB")
      (check-equal? "x/apple|" (test-user:text))
      (check-equal? '() exits)
      (check-equal? '("apple" "applet") (texts))
      (test-user:press! "M-n M-n RET")
      (check-equal? #f (session))
      (check-equal? '((tabbed "applet" finished "x/applet|")) exits))))

(test "typing on after TAB changes the match's text, so no exit is called"
  (set! exits '())
  (with-region tabbed-region
    (lambda ()
      (test-user:show! "x/appl|")
      (test-user:press! "C-M-i M-n TAB")
      (test-user:type! "x")
      (test-user:press! "C-g")
      (check-equal? #f (session))
      (check-equal? '() exits))))

(test "TAB on the one match left ends the session with finished"
  (set! exits '())
  (with-region tabbed-region
    (lambda ()
      (test-user:show! "x/appl|")
      (test-user:press! "C-M-i M-n M-n TAB")
      (check-equal? #f (session))
      (check-equal? '((tabbed "applet" finished "x/applet|")) exits))))

(test "a region of two sources calls the exit of the source whose candidate was chosen"
  (set! exits '())
  (let ([two (lambda ()
               (let ([s (word-start)])
                 (and s (completion:region s (views:point (views:current))
                          (list (completion:source (candidates (vector "apple")) (exit (exit-noting 'fruit)))
                                (completion:source (candidates (vector "avocado")) (exit (exit-noting 'vegetable))))))))])
    (with-region two
      (lambda ()
        (test-user:show! "a|")
        (test-user:press! "C-M-i")
        (check-equal? '("apple" "avocado") (texts))
        (test-user:press! "M-n M-n RET")
        (check-equal? '((vegetable "avocado" finished "avocado|")) exits)))))

(test "a read calls no exit"
  (set! exits '())
  (let ([r (completion-test/sessions:start! (lambda () (completion:read "Fruit: " (list (completion:source (candidates (vector "apple")) (exit (exit-noting 'read)))) #f)))])
    (test-user:press! "RET")
    (check-equal? "apple" (completion-test/sessions:result r))
    (check-equal? '() exits)))

(define (zeds)
  (let ([s (word-start)])
    (and s (completion:region s (views:point (views:current)) (list (completion:source (candidates (vector "zeta" "zero")) (styles (list completion:substring))))))))

(define (greek-fallback)
  (let ([s (word-start)])
    (and s (completion:fallback-region s (views:point (views:current)) (list (completion:source (candidates (vector "alpha" "almond"))))))))

(test "C-M-i in a region whose sources find nothing says No match once, and the session stays"
  (with-region zeds
    (lambda ()
      (test-user:show! "q|")
      (test-user:press! "C-M-i")
      (check (session))
      (check-equal? '() (texts))
      (check-equal? "No match" (echo-area:current-message))
      (test-user:type! "q")
      (check-equal? #f (echo-area:current-message)))))

(test "a fallback region whose sources find nothing gives way to the next entry's region, at the start and as the text changes"
  (hooks:add! completion:find-region greek-fallback -2)
  (hooks:add! completion:find-region zeds -1)
  (test-user:show! "al|")
  (test-user:press! "C-M-i")
  (check-equal? '("alpha" "almond") (texts))
  (test-user:press! "C-g")
  (test-user:show! "ze|")
  (test-user:press! "C-M-i")
  (check-equal? '("zero" "zeta") (texts))
  (test-user:press! "C-g")
  (test-user:show! "al|")
  (test-user:press! "C-M-i")
  (test-user:type! "x")
  (check-equal? '() (texts))
  (test-user:press! "DEL DEL")
  (check-equal? '("zeta") (texts))
  (test-user:press! "C-g")
  (hooks:remove! completion:find-region greek-fallback)
  (hooks:remove! completion:find-region zeds))

(test "a fallback stream gives way once it has said done; with no region after it C-M-i says No match then, and start-at-point says nothing"
  (let* ([emit #f]
         [empty-stream (lambda ()
                         (let ([s (word-start)])
                           (and s (completion:fallback-region s (views:point (views:current))
                                    (list (completion:source (stream (lambda (e) (set! emit e) (lambda (prefix) (void))))))))))])
    (hooks:add! completion:find-region empty-stream)
    (test-user:show! "xy|")
    (test-user:press! "C-M-i")
    (check (session))
    (check-equal? #f (echo-area:current-message))
    (emit 'done)
    (test-runner:wait-until (lambda () (not (session))))
    (check-equal? "No match" (echo-area:current-message))
    (test-user:show! "xy|")
    (echo-area:message! "")
    (check-equal? #t (start-at-point 0))
    (emit 'done)
    (test-runner:wait-until (lambda () (not (session))))
    (check-equal? #f (echo-area:current-message))
    (hooks:remove! completion:find-region empty-stream)))

(test "start-from-entry uses one entry, ignoring the hook, and calls its procedure when a fallback region finds nothing"
  (hooks:add! completion:find-region zeds)
  (test-user:show! "al|")
  (check-equal? #t (completion-test/sessions:result (completion-test/sessions:start! (lambda () (completion:start-from-entry zeds)))))
  (check-equal? '() (texts))
  (test-user:press! "C-g")
  (check-equal? #t (completion-test/sessions:result (completion-test/sessions:start! (lambda () (completion:start-from-entry greek-fallback)))))
  (check-equal? '("alpha" "almond") (texts))
  (test-user:press! "C-g")
  (test-user:show! "q|")
  (let ([said 0])
    (check-equal? #t (completion-test/sessions:result (completion-test/sessions:start! (lambda () (completion:start-from-entry greek-fallback (lambda () (set! said (+ said 1))))))))
    (check-equal? (list #f 1) (list (session) said)))
  (test-user:show! "q |")
  (check-equal? #f (completion-test/sessions:result (completion-test/sessions:start! (lambda () (completion:start-from-entry greek-fallback)))))
  (hooks:remove! completion:find-region zeds))

(test "the procedures that start sessions at point check their arguments"
  (check-raises (raised? 'completion:start-from-entry "not a procedure") (completion:start-from-entry 'greek))
  (check-raises (raised? 'completion:start-at-point "not a procedure") (completion:start-at-point 0 "No match"))
  (check-raises (raised? 'completion:fallback-region "not a start and an end") (completion:fallback-region 3 1 '())))

(test "a session at point waits for its sources' first answer: busy with no matches at the key, and No match only once they answer"
  (let* ([emit #f]
         [later (lambda ()
                  (let ([s (word-start)])
                    (and s (completion:region s (views:point (views:current))
                             (list (completion:source (stream (lambda (e) (set! emit e) (lambda (prefix) (void))))))))))])
    (with-region later
      (lambda ()
        (test-user:show! "zz|")
        (test-user:press! "C-M-i")
        (check-equal? #t (completion:session-busy? (session)))
        (check-equal? '() (texts))
        (check-equal? #f (echo-area:current-message))
        (emit 'done)
        (test-runner:wait-until (lambda () (equal? "No match" (echo-area:current-message))))
        (check (session))))))

(test "a session at point in a prompt is no read's: the prompt keeps its input, and the choice goes into it"
  (let ([prompt-words (lambda ()
                        (let ([p (minibuffer:current-prompt)])
                          (and p (eq? (views:current) (minibuffer:prompt-view p))
                               (completion:region (minibuffer:input-start p) (views:point (views:current))
                                 (list (completion:source (candidates (vector "alpha" "almond"))))))))])
    (with-region prompt-words
      (lambda ()
        (let ([r (completion-test/sessions:start! (lambda () (minibuffer:read "Eval: " #f)))])
          (test-user:type! "al")
          (test-user:press! "C-M-i")
          (check-equal? '("alpha" "almond") (texts))
          (check-equal? #f (completion:session-prompt (session)))
          (test-user:press! "M-n RET")
          (check-equal? "alpha" (completion-test/sessions:input))
          (check-equal? #f (session))
          (test-user:press! "RET")
          (check-equal? "alpha" (completion-test/sessions:result r)))))))

(define (prefix-region)
  (let* ([v (views:current)] [p (views:point v)] [s (editing:forward-word-position (views:buffer v) p -1)])
    (and (< s p) (completion:region s p (list greek)))))

(test "C-b inside the word keeps the session over the whole first region, and RET replaces all of it"
  (set! exits '())
  (with-region prefix-region
    (lambda ()
      (test-user:show! "alp|")
      (test-user:press! "C-M-i C-b")
      (check-equal? '("alpha" "alpine" "alphabet") (texts))
      (test-user:press! "M-n M-n RET")
      (check-equal? "alpine|" (test-user:text))
      (check-equal? '((greek "alpine" finished "alpine|")) exits))))

(test "C-f past the end of the first region ends the session"
  (with-region prefix-region
    (lambda ()
      (test-user:show! "alp|x")
      (test-user:press! "C-M-i")
      (check (session))
      (test-user:press! "C-f")
      (check-equal? #f (session)))))

(test "typing until the word is the only match keeps the session with its one row and calls no exit; SPC then ends it, still with none"
  (set! exits '())
  (with-region greek-region
    (lambda ()
      (test-user:show! "alp|")
      (test-user:press! "C-M-i")
      (test-user:type! "ine")
      (check (session))
      (check-equal? '("alpine") (texts))
      (test-user:type! " ")
      (check-equal? #f (session))
      (check-equal? '() exits))))

(test "a session with no matches holds no key, so C-n moves to the next line; C-g still ends it"
  (with-region prefix-region
    (lambda ()
      (test-user:show! "alp|\nnext")
      (test-user:press! "C-M-i")
      (test-user:type! "z")
      (check-equal? '() (texts))
      (test-user:press! "C-g")
      (check-equal? #f (session))
      (test-user:show! "alp|\nnext")
      (test-user:press! "C-M-i")
      (test-user:type! "z")
      (test-user:press! "DEL M-n")
      (check-equal? "alpha" (completion-test/sessions:selected-text (session)))
      (test-user:type! "z")
      (test-user:press! "C-n")
      (check-equal? "alpz\nnext|" (test-user:text))
      (check-equal? #f (session)))))
