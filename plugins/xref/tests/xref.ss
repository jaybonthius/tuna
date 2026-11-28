(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (commands) (keys) (buffers) (document) (views)
        (layout) (layout-split) (editing) (files) (minibuffer) (completion) (completion-list) (jump-history) (xref) (xref-test words)
        (minibuffer-test screen))

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

(define (reports-during thunk)
  (map (lambda (c) (if (cancelled? c) 'cancelled (list (condition-who c) (condition-message c)))) (test-runner:reports-during thunk)))

;; A command may pause past test-user:settle, as when it visits a file,
;; so a test that needs it done waits for its end.
(define ended '())

(hooks:add! commands:after-command (lambda (command) (set! ended (cons command ended))))

(define (press-until-ended! keys command)
  (set! ended '())
  (test-user:press! keys)
  (test-runner:wait-until (lambda () (memq command ended))))

;; The kernel reports the end of a command quit while it waits.
(define (quit!)
  (check-equal? '(cancelled) (reports-during (lambda () (test-user:press! "C-g")))))

(define (view) (layout:selected-view))

(define (here)
  (let* ([v (view)] [b (views:buffer v)])
    (list (buffers:name b) (document:line (buffers:document b) (views:point v)))))

(define (places)
  (map (lambda (p) (list (buffers:name (car p)) (document:line (buffers:document (car p)) (cdr p))))
       (jump-history:places)))

(define (session) (views:call-with-view (view) completion:current-session))

(define (choices)
  (let ([s (session)])
    (test-runner:wait-until (lambda () (not (completion:session-busy? s))))
    (let ([ms (completion:session-matches s)])
      (map (lambda (k) (completion:text s (completion:matches-ref ms k))) (iota (completion:matches-count ms))))))

(define (prompting?) (and (minibuffer:current-prompt) #t))

(define uses (files:visit (xref-test/words:path "uses.txt")))

(define (to-word! word line)
  (let* ([doc (buffers:document uses)] [start (document:line-start doc line)]
         [text (document:text doc start (document:length doc))])
    (let loop ([i 0])
      (if (string=? (substring text i (+ i (string-length word))) word)
          (views:set-point! (view) (+ start i 1))
          (loop (+ i 1))))))

(test-user:show! "|one\ntwo\n")

(test "with no backend for the buffer, the commands say so"
  (check-equal? '((xref:find-definitions "No xref backend")) (reports-during (lambda () (test-user:press! "M-."))))
  (check-raises (raised? 'xref:apropos "No xref backend") (xref:apropos (view) "t")))

(test "one definition goes there, a jump into another file recording the place it left, so M-, returns"
  (layout:switch-to-buffer uses)
  (to-word! "average" 2)
  (press-until-ended! "M-." xref:find-definitions)
  (check-equal? '(("defs.txt" 2) (("uses.txt" 2))) (list (here) (places)))
  (test-user:press! "M-,")
  (check-equal? '("uses.txt" 2) (here)))

(test "several definitions are asked about through xref:choose-and-go, each labelled by its path, line and summary"
  (to-word! "total" 1)
  (test-user:press! "M-.")
  (check-equal? '("~/code/defs.txt:1: def total" "~/code/sub/twice.txt:2: def total") (choices))
  (check-equal? "Definitions of total: " (minibuffer-test/screen:question))
  (press-until-ended! "C-n RET" xref:find-definitions)
  (check-equal? '(("twice.txt" 2) (("uses.txt" 1))) (list (here) (places)))
  (test-user:press! "M-,"))

(test "a quit while choosing records nothing"
  (let ([before (places)])
    (test-user:press! "M-.")
    (quit!)
    (check-equal? (list '("uses.txt" 1) before #f) (list (here) (places) (prompting?)))))

(test "a display that returns at once leaves the command ended and the place it started from recorded"
  (let ([shown '()])
    (options:set! xref:definitions-display (lambda (items title) (set! shown (list title (length items)))))
    (test-user:press! "M-.")
    (check-equal? '(("Definitions of total" 2) ("uses.txt" 1) ("uses.txt" 1) #f)
                  (list shown (here) (car (places)) (prompting?)))
    (options:unset! xref:definitions-display)))

(test "with xref:auto-jump-to-first-definition?, M-. goes to the first of several without asking"
  (options:set! xref:auto-jump-to-first-definition? #t)
  (press-until-ended! "M-." xref:find-definitions)
  (check-equal? '(("defs.txt" 1) #f) (list (here) (prompting?)))
  (test-user:press! "M-,")
  (options:unset! xref:auto-jump-to-first-definition?))

(test "C-u M-. asks, naming the identifier at point as the default and completing over the backend's identifiers, and takes a name that is not one"
  (test-user:press! "C-u M-.")
  (check-equal? "Find definitions of (default total): " (minibuffer-test/screen:question))
  (test-user:type! "ta")
  (check-equal? '("total" "tally") (choices))
  (test-user:press! "C-a C-k")
  (test-user:type! "zzz")
  (check-equal? '((xref:find-definitions "No definitions found for: zzz"))
                (reports-during (lambda () (test-user:press! "RET")))))

(test "M-? asks by default, as xref:prompt-for-identifier lists it, and RET on the empty input takes the identifier at point"
  (test-user:press! "M-?")
  (check-equal? "Find references of (default total): " (minibuffer-test/screen:question))
  (test-user:press! "RET")
  (check-equal? '("~/code/uses.txt:1: x = total" "~/code/uses.txt:2: y = average + total") (choices))
  (check-equal? "References of total: " (minibuffer-test/screen:question))
  (quit!))

(test "where there is no identifier at point the question names no default"
  (views:set-point! (view) (- (document:length (buffers:document uses)) 1))
  (test-user:press! "M-.")
  (check-equal? "Find definitions of: " (minibuffer-test/screen:question))
  (quit!))

(test "with xref:prompt-for-identifier #f and xref:auto-jump-to-first-reference?, M-? goes to the first reference; with #t, M-. asks too"
  (options:set! xref:prompt-for-identifier #f xref:auto-jump-to-first-reference? #t)
  (to-word! "total" 2)
  (press-until-ended! "M-?" xref:find-references)
  (check-equal? '(("uses.txt" 1) #f) (list (here) (prompting?)))
  (options:set! xref:prompt-for-identifier #t)
  (test-user:press! "M-.")
  (check (prompting?))
  (quit!)
  (options:unset! xref:prompt-for-identifier xref:auto-jump-to-first-reference?))

(test "a jump to an item runs jump-history:after-jump with the view"
  (let ([jumped '()])
    (define (note-jump v) (set! jumped (cons v jumped)))
    (hooks:add! jump-history:after-jump note-jump)
    (to-word! "average" 2)
    (press-until-ended! "M-." xref:find-definitions)
    (check-equal? (list (view)) jumped)
    (check-equal? '("defs.txt" 2) (here))
    (hooks:remove! jump-history:after-jump note-jump)
    (test-user:press! "M-,")))

(test "an item keeps its summary, path, line, column and kind, and its arguments are checked"
  (let ([item (xref:make-item "a" (xref-test/words:path "defs.txt") 3 4 "Function")] [plain (xref:make-item "b" (xref-test/words:path "uses.txt") 1 0)])
    (check-equal? (list "a" (xref-test/words:path "defs.txt") 3 4 "Function")
                  (list (xref:item-summary item) (xref:item-path item) (xref:item-line item) (xref:item-column item) (xref:item-kind item)))
    (check-equal? '(#t #f) (list (xref:item? plain) (xref:item-kind plain))))
  (check-raises (raised? 'xref:make-item "not an absolute path") (xref:make-item "a" "relative.txt" 1 0))
  (check-raises (raised? 'xref:make-item "not a line number") (xref:make-item "a" "/a.txt" 0 0))
  (check-raises (raised? 'xref:make-item "not a column") (xref:make-item "a" "/a.txt" 1 -1))
  (check-raises (raised? 'xref:make-item "neither a string nor #f") (xref:make-item "a" "/a.txt" 1 0 'function)))

(commands:define-command (show-two) "Shows two items."
  (xref:show-items (list (xref:make-item "a" (xref-test/words:path "defs.txt") 3 4) (xref:make-item "b" (xref-test/words:path "uses.txt") 1 0)) "Found"))

(keys:bind! keys:global "C-c x" show-two)

(test "xref:show-items shows a command's own items under its title, and records the place it started from"
  (to-word! "average" 2)
  (test-user:press! "C-c x")
  (check-equal? '("~/code/defs.txt:3: a" "~/code/uses.txt:1: b") (choices))
  (check-equal? "Found: " (minibuffer-test/screen:question))
  (press-until-ended! "RET" show-two)
  (check-equal? '(("defs.txt" 3) ("uses.txt" 2)) (list (here) (car (places))))
  (test-user:press! "M-,"))

(test "xref:go-to-item puts point at the item's column, or at the end of a line shorter than that"
  (xref:go-to-item (xref:make-item "x" (xref-test/words:path "uses.txt") 1 4))
  (check-equal? "x = |total\ny = average + total\n" (test-user:text))
  (xref:go-to-item (xref:make-item "x" (xref-test/words:path "uses.txt") 1 40))
  (check-equal? "x = total|\ny = average + total\n" (test-user:text)))

(test "C-M-. asks for a pattern and shows the identifiers that match it under Symbols matching, through xref:references-display; none raises"
  (let ([shown '()])
    (options:set! xref:references-display (lambda (items title) (set! shown (list title (map xref:item-summary items)))))
    (test-user:press! "C-M-.")
    (check-equal? "Search for symbols matching: " (minibuffer-test/screen:question))
    (test-user:type! "ta")
    (test-user:press! "RET")
    (check-equal? '("Symbols matching ta" ("def total" "def tally" "def total")) shown)
    (test-user:press! "C-M-.")
    (test-user:type! "zz")
    (check-equal? '((xref:find-apropos "No matches for: zz")) (reports-during (lambda () (test-user:press! "RET"))))
    (options:unset! xref:references-display))
  (check-equal? '("def average") (map xref:item-summary (xref:apropos (view) "av"))))

(test "a backend without a clause cannot do what it would do, and the command says so"
  (let ([bare (xref:backend "bare")])
    (define (bare-backend v) bare)
    (buffers:with-buffer uses (hooks:add-local! xref:backends bare-backend -1))
    (check-equal? '((xref:find-definitions "The xref backend bare cannot find definitions"))
                  (reports-during (lambda () (test-user:press! "C-u M-.") (test-user:type! "x") (test-user:press! "RET"))))
    (check-raises (raised? 'xref:apropos "The xref backend bare cannot search identifiers") (xref:apropos (view) "x"))
    (buffers:with-buffer uses (hooks:remove-local! xref:backends bare-backend))))

(test "a backend's answer that is not a list of items raises"
  (let ([odd (xref:backend "odd" [apropos (lambda (pattern) 5)])])
    (define (odd-backend v) odd)
    (buffers:with-buffer uses (hooks:add-local! xref:backends odd-backend -1))
    (check-raises (raised? 'xref:apropos "a backend returned what is not a list of items") (xref:apropos (view) "x"))
    (buffers:with-buffer uses (hooks:remove-local! xref:backends odd-backend))))

(test "an entry of xref:backends that returns neither a backend nor #f raises, and one that returns #f gives way to the next"
  (define (none v) #f)
  (define (odd v) 'odd)
  (buffers:with-buffer uses (hooks:add-local! xref:backends none -2))
  (check-equal? '("def average") (map xref:item-summary (xref:apropos (view) "av")))
  (buffers:with-buffer uses (hooks:add-local! xref:backends odd -1))
  (check-raises (raised? 'xref:backends "an entry returned neither a backend nor #f") (xref:apropos (view) "av"))
  (buffers:with-buffer uses (hooks:remove-local! xref:backends odd))
  (buffers:with-buffer uses (hooks:remove-local! xref:backends none)))

(test "an unknown clause, or a clause given twice, is a syntax error"
  (for-each
    (lambda (module message)
      (check-raises (lambda (c) (and (syntax-violation? c) (string=? message (condition-message c))))
                    (load-module! (list 'xref-test 'bad-backend module))))
    '(unknown-clause clause-twice)
    '("invalid clause" "clause given twice")))

(test "C-x 4 . shows the definition in another view, which it selects; the view it came from keeps its buffer and point"
  (layout:switch-to-buffer uses)
  (to-word! "average" 2)
  (let* ([from (view)] [at (views:point from)])
    (press-until-ended! "C-x 4 ." xref:find-definitions-other-view)
    (check-equal? (list #f '("defs.txt" 2) uses at)
                  (list (eq? (view) from) (here) (views:buffer from) (views:point from)))
    (layout:select! from)
    (test-user:press! "C-x 1")))

(test "with several definitions, C-x 4 . asks first, then shows the one chosen in another view"
  (to-word! "total" 1)
  (let ([from (view)])
    (test-user:press! "C-x 4 .")
    (check-equal? '("~/code/defs.txt:1: def total" "~/code/sub/twice.txt:2: def total") (choices))
    (press-until-ended! "C-n RET" xref:find-definitions-other-view)
    (check-equal? (list #f '("twice.txt" 2) uses) (list (eq? (view) from) (here) (views:buffer from)))))
