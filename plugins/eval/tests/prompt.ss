(import (tuna) (test) (eval-test caught-reports) (test-runner) (test-user) (hooks) (tables) (saved) (commands) (keys) (buffers) (views) (layout) (layout-split)
        (editing) (echo-area) (undo) (minibuffer) (completion) (files) (chez-scheme) (chez-scheme-completion) (eval)
        (eval-test))

(define (message) (echo-area:current-message))

(eval-test:show! (buffers:make "notes" "alpha\n"))

(define (quit!) (eval-test:reports-during (lambda () (test-user:press! "C-g"))))

(test "RET ends the prompt only when its input reads as one expression; otherwise the prompt says why and point goes where reading stopped"
  (test-user:press! "M-:")
  (test-user:type! "(+ 1")
  (test-user:press! "RET")
  (check-equal? '("(+ 1" " [unexpected end-of-file reading list]" 4)
    (list (eval-test:input) (eval-test:prompt-message) (eval-test:input-point)))
  (test-user:press! "C-a C-k RET")
  (check-equal? '("" " [no expression]") (list (eval-test:input) (eval-test:prompt-message))))

(test "with text after the expression, point goes before that text and no mark is set; a comment after it is no text"
  (test-user:type! "1 2")
  (test-user:press! "RET")
  (check-equal? '(" [text after the expression]" 2 #f)
    (list (eval-test:prompt-message) (eval-test:input-point) (views:mark (minibuffer:prompt-view (eval-test:prompt)))))
  (test-user:press! "C-a C-k")
  (test-user:type! "1 ;; one")
  (test-user:press! "RET")
  (check-equal? '(#f "1") (list (eval-test:prompt) (message))))

(test "C-j ends the prompt as RET does"
  (test-user:press! "M-:")
  (test-user:type! "(+ 1 2)")
  (test-user:press! "C-j")
  (check-equal? "3" (message)))

(test "C-g closes the prompt, evaluates nothing and says Quit, and the history does not gain the input"
  (test-user:press! "M-:")
  (test-user:type! "(+ 1")
  (check-equal? '(cancelled) (quit!))
  (check-equal? '(#f "Quit" ("(+ 1 2)" "1 ;; one")) (list (eval-test:prompt) (message) (eval:expression-history))))

(test "M-p recalls the newest input first, from M-:'s own history, which other prompts' inputs do not reach and which is saved"
  (saved:set! minibuffer:history '("from another prompt"))
  (test-user:press! "M-:")
  (test-user:press! "M-p")
  (check-equal? "(+ 1 2)" (eval-test:input))
  (test-user:press! "M-p")
  (check-equal? "1 ;; one" (eval-test:input))
  (check-equal? '((minibuffer:previous-history "beginning of history"))
    (eval-test:reports-during (lambda () (test-user:press! "M-p"))))
  (check-equal? "1 ;; one" (eval-test:input))
  (check-equal? '(cancelled) (quit!))
  (check (saved:saved? eval:expression-history)))

(define (wait-for-matches)
  (test-runner:wait-until
    (lambda () (let ([s (eval-test:session)]) (and s (not (completion:session-busy? s)))))))

(test "TAB completes the Scheme name before point from the REPL's names, listing the candidates at once; TAB again completes the sole one"
  (test-user:press! "M-:")
  (test-user:type! "(buffers:ins")
  (test-user:press! "TAB")
  (wait-for-matches)
  (check-equal? '("buffers:insert!") (eval-test:session-texts))
  (test-user:press! "TAB")
  (check-equal? '("(buffers:insert!" #f) (list (eval-test:input) (eval-test:session)))
  (test-user:press! "C-a C-k"))

(eval-test:write-greet!)

(import (greet))

(test "after a quote, completion starts after the quote"
  (test-user:type! "'greet:te")
  (test-user:press! "TAB")
  (wait-for-matches)
  (test-user:press! "TAB")
  (check-equal? "'greet:text" (eval-test:input))
  (check-equal? '(cancelled) (quit!)))

(define (open-other-prompt!)
  (spawn-task (lambda (restore) (views:call-with-view (eval-test:view) (lambda () (minibuffer:read "Other: ")))))
  (test-user:settle))

(test "another prompt gets no Scheme names: eval's entry of completion:find-region answers only in M-:'s prompt"
  (open-other-prompt!)
  (test-user:type! "buffers:ins")
  (test-user:press! "M-TAB")
  (check-equal? '("buffers:ins" #f) (list (eval-test:input) (eval-test:session)))
  (check-equal? '(cancelled) (quit!)))

(tables:define-table own-keymap "Keys the test adds to the prompt.")

(define calls '())

(commands:define-command (mark-it) "Notes a key." (set! calls (cons 'key calls)))

(keys:bind! own-keymap "C-c C-c" mark-it)

(define (add-own p) (set! calls (cons (minibuffer:prompt? p) calls)) (minibuffer:add-keymap! p own-keymap))

(define (note-started p) (set! calls (cons 'started calls)))

(test "an entry of eval:expression-prompt-started runs once with the prompt, before minibuffer:prompt-started and any key; a keymap it adds works in this prompt only"
  (hooks:add! eval:expression-prompt-started add-own)
  (hooks:add! minibuffer:prompt-started note-started)
  (test-user:press! "M-:")
  (check-equal? '(#t started) (reverse calls))
  (test-user:press! "C-c C-c")
  (check-equal? '(#t started key) (reverse calls))
  (check-equal? '(cancelled) (quit!))
  (hooks:remove! eval:expression-prompt-started add-own)
  (open-other-prompt!)
  (check-equal? '((#f "C-c C-c is undefined"))
    (map (lambda (r) (if (pair? r) r 'cancelled)) (eval-test:reports-during (lambda () (test-user:press! "C-c C-c")))))
  (check-equal? '(#t started key started) (reverse calls))
  (check-equal? '(cancelled) (quit!))
  (hooks:remove! minibuffer:prompt-started note-started))
