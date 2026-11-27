(import (tuna) (test) (eval-test caught-reports) (test-user) (keys) (document) (buffers) (views) (layout) (layout-split) (editing) (echo-area)
        (undo) (modes) (minibuffer) (completion) (files) (actions) (chez-scheme) (chez-scheme-completion) (eval)
        (eval-test))

(define (message) (echo-area:current-message))

(define (unbound? c) (and (message-condition? c) (equal? "variable ~:s is not bound" (condition-message c))))

(define code (eval-test:scheme-buffer! "code.ss" "(define (f x) (* x 2))\n\n(+ 40 2)\n\n(f 5)\n"))

(test "C-c C-r in a Scheme buffer evaluates the region's forms in order and shows the last one's value; point and the region stay"
  (eval-test:at! code "(define" 0)
  (eval-test:mark-at! code "\n\n(+" 0)
  (test-user:press! "C-c C-r")
  (check-equal? "f" (message))
  (eval-test:at! code "(+ 40" 0)
  (eval-test:mark-at! code "(f 5)" 5)
  (let ([spots (list (views:point (eval-test:view)) (views:mark (eval-test:view)))])
    (test-user:press! "C-c C-r")
    (check-equal? (list "10" '("10") spots)
      (list (message) (eval-test:log-tail 1) (list (views:point (eval-test:view)) (views:mark (eval-test:view)))))))

(test "a prefix argument changes nothing"
  (test-user:press! "C-u C-c C-r")
  (check-equal? '("10" "(define (f x) (* x 2))\n\n|(+ 40 2)\n\n(f 5)\n") (list (message) (test-user:text))))

(test "what the forms write shows, void is left out, and No value is not written after output"
  (let ([out (eval-test:scheme-buffer! "out.ss" "(display \"x\")\n")])
    (views:set-point! (eval-test:view) 1)
    (eval-test:mark-at! out "\n" 0)
    (test-user:press! "C-c C-r")
    (check-equal? "x" (message))))

(test "with no mark there is no region"
  (views:set-mark! (eval-test:view) #f)
  (check-equal? '((eval:region "the mark is not set, so there is no region"))
    (eval-test:reports-during (lambda () (test-user:press! "C-c C-r"))))
  (check-equal? "the mark is not set, so there is no region" (message)))

(test "an error stops the forms, and those after it do not run"
  (let ([bad (eval-test:scheme-buffer! "bad.ss" "(car 1) (define after-bad 2)")])
    (views:set-point! (eval-test:view) 1)
    (eval-test:mark-at! bad "2)" 2)
    (check-equal? '((car "~s is not a pair")) (eval-test:reports-during (lambda () (test-user:press! "C-c C-r"))))
    (check-equal? "1 is not a pair" (message))
    (check-raises unbound? (eval:eval-text "after-bad"))))

(test "a read error counts its position from the region's start"
  (let ([open (eval-test:scheme-buffer! "open.ss" "(+ 1")])
    (views:set-point! (eval-test:view) 1)
    (eval-test:mark-at! open "1" 1)
    (let ([reports (eval-test/caught-reports:during (lambda () (test-user:press! "C-c C-r")))])
      (check-equal? '(#t) (map lexical-violation? reports))
      (check-equal? "unexpected end-of-file reading list at char 0 of #<input port string>" (message)))))

(test "a definition shows its name, after any plugin's prefix"
  (let ([cmd (eval-test:scheme-buffer! "cmd.ss" "(commands:define-command (say-hello) \"Says hello.\" (echo-area:message! \"Hello\"))\n")])
    (views:set-point! (eval-test:view) 1)
    (eval-test:mark-at! cmd "\n" 0)
    (test-user:press! "C-c C-r")
    (check-equal? "say-hello" (message))))

(eval-test:write-greet!)

(import (greet))

(test "in a loaded module's file the region evaluates in the module, where a define of one of its names redefines it"
  (let ([greet-file (eval-test:show! (files:visit (eval-test:home-path ".config/tuna/lib/greet.sls")))])
    (buffers:insert! greet-file (- (document:length (buffers:document greet-file)) 1)
      "(define (text n) (string-append \"Hi, \" n))\n")
    (eval-test:at! greet-file "(define (text n) (string-append \"Hi" 0)
    (eval-test:mark-at! greet-file "n))\n" 4)
    (test-user:press! "C-c C-r")
    (check-equal? '("text" "Hi, a") (list (message) (greet:text "a")))))

(test "e in the actions on a region runs eval:region on it"
  (eval-test:show! code)
  (eval-test:at! code "(+ 40" 0)
  (eval-test:mark-at! code "(f 5)" 5)
  (echo-area:message! "")
  (test-user:press! "C-. e")
  (check-equal? "10" (message)))

(test "on an expression in a Scheme buffer, e and C-; evaluate it"
  (let ([nested (eval-test:scheme-buffer! "nested.ss" "(list (+ 1 2))\n")])
    (eval-test:at! nested "(+ 1" 0)
    (test-user:press! "C-. e")
    (check-equal? "3" (message))
    (echo-area:message! "")
    (test-user:press! "C-;")
    (check-equal? "3" (message))))

(test "on a top-level definition, e evaluates it and shows its name"
  (eval-test:show! code)
  (views:set-mark! (eval-test:view) #f)
  (eval-test:at! code "(define" 0)
  (test-user:press! "C-. e")
  (check-equal? '("f" ("f")) (list (message) (eval-test:log-tail 1))))

(test "on a Scheme name, e evaluates the name and shows its value"
  (let ([names (eval-test:scheme-buffer! "names.ss" "(list chez-scheme:mode)\n")])
    (eval-test:at! names "mode)" 1)
    (test-user:press! "C-.")
    (check-equal? "Act on chez-scheme:mode: " (keys:reading-prompt (test-user:client)))
    (test-user:press! "e")
    (check-equal? "chez-scheme:mode" (message))))
