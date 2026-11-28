(import (tuna) (test) (eval-test caught-reports) (test-user) (files) (auto-mode) (document) (buffers) (views) (layout) (layout-split)
        (editing) (echo-area) (undo) (modes) (minibuffer) (completion) (chez-scheme) (chez-scheme-completion) (eval)
        (eval-test))

(define (message) (echo-area:current-message))

(define (unbound? c) (and (message-condition? c) (equal? "variable ~:s is not bound" (condition-message c))))

(define (bound? name) (guard (c [(unbound? c) #f]) (eval:eval-text name) #t))

(define (shown-after keys)
  (let* ([shown #f] [reports (eval-test:reports-during (lambda () (set! shown (eval-test:after-message (lambda () (test-user:press! keys))))))])
    (list shown reports)))

(eval-test:write-file! "notes.ss" "(define n 1)\n(display \"hi\")\n")

(define notes (eval-test:show! (files:visit (eval-test:home-path "notes.ss"))))

(test "C-c C-k evaluates a buffer's file as the REPL: what it writes shows, then Evaluated the NAME buffer; point stays"
  (eval-test:at! notes "(display" 0)
  (check-equal? '("Evaluated the notes.ss buffer" ()) (shown-after "C-c C-k"))
  (check-equal? (list '("hi" "Evaluated the notes.ss buffer") 1 "(define n 1)\n|(display \"hi\")\n")
    (list (eval-test:log-tail 2) (eval:eval-text "n") (test-user:text))))

(test "a modified buffer asks to be saved first, and the answer is echoed with the question: y saves it, then evaluates the file"
  (buffers:insert! notes 1 "(define m 2)\n")
  (test-user:press! "C-c C-k")
  (check-equal? "Save notes.ss first? (y or n) \n" (eval-test:prompt-text))
  (check-equal? '("Save notes.ss first? (y or n) y" "Wrote ~/notes.ss" "hi" "Evaluated the notes.ss buffer")
    (eval-test:logged-after 4 (lambda () (test-user:press! "y"))))
  (check-equal? "Evaluated the notes.ss buffer" (message))
  (check-equal? (list #f 2) (list (buffers:modified? notes) (eval:eval-text "m"))))

(test "n evaluates the file as saved, without the buffer's edits"
  (buffers:insert! notes 1 "(define k 3)\n")
  (test-user:press! "C-c C-k")
  (check-equal? '("Save notes.ss first? (y or n) n" "hi" "Evaluated the notes.ss buffer")
    (eval-test:logged-after 3 (lambda () (test-user:press! "n"))))
  (check-equal? (list #t #f) (list (buffers:modified? notes) (bound? "k"))))

(test "C-g at the question saves and evaluates nothing, and says Quit"
  (let ([logged (length (eval-test:log-tail 1000))])
    (test-user:press! "C-c C-k")
    (check-equal? '(cancelled) (eval-test:reports-during (lambda () (test-user:press! "C-g"))))
    (check-equal? (list #t (+ logged 1) "Quit") (list (buffers:modified? notes) (length (eval-test:log-tail 1000)) (message))))
  (files:save-buffer notes))

(test "a raise stops a file that is no module: what it wrote is logged before the report, the forms after it do not run, and no Evaluated line shows"
  (eval-test:write-file! "failing.ss" "(display \"a\")\n(car 1)\n(define after #t)\n")
  (eval-test:show! (files:visit (eval-test:home-path "failing.ss")))
  (check-equal? '("1 is not a pair" ((car "~s is not a pair"))) (shown-after "C-c C-k"))
  (check-equal? (list '("a" "car: 1 is not a pair") #f) (list (eval-test:log-tail 2) (bound? "after"))))

(eval-test:write-greet!)

(import (greet))

(define greet-path ".config/tuna/lib/greet.sls")

(define (greet-reload! text)
  (eval-test:write-file! greet-path text)
  (shown-after "C-c C-k"))

(test "a loaded module's file reloads the module"
  (eval-test:show! (files:visit (eval-test:home-path greet-path)))
  (check-equal? '("Evaluated the greet.sls buffer" ()) (greet-reload! "#!tuna\n(define (text n) (string-append \"Hi, \" n \"!\"))\n"))
  (check-equal? "Hi, a!" (greet:text "a")))

(test "a reload whose body raises is reported, the previous version runs again, and no Evaluated line shows"
  (check-equal? '("1 is not a pair" ((car "~s is not a pair"))) (greet-reload! "#!tuna\n(define (text n) n)\n(car 1)\n"))
  (check-equal? "Hi, a!" (greet:text "a")))

(test "so is one that fails to compile"
  (check-equal? "invalid syntax" (car (greet-reload! "#!tuna\n(define (text n) n)\n(define)\n")))
  (check-equal? "Hi, a!" (greet:text "a")))

(test "a reload that only warns shows its warning, with no Evaluated line"
  (check-equal? '("possible incorrect argument count in call (car)" ((compile "possible incorrect argument count in call ~a")))
    (greet-reload! "#!tuna\n(define (text n) (string-append \"Hey, \" n))\n(define (w) (car))\n"))
  (check-equal? '("Hey, a" warning) (list (greet:text "a") (echo-area:current-face))))

(define (raise-after loaded instance)
  (loaded instance)
  (when (equal? (owner-name instance) '(greet)) (car 2)))

(test "a good reload during which an advice of module-loaded raises is reported, with no Evaluated line"
  (advice-add! module-loaded raise-after)
  (check-equal? '("2 is not a pair" ((car "~s is not a pair"))) (greet-reload! "#!tuna\n(define (text n) (string-append \"Yo, \" n))\n"))
  (advice-remove! module-loaded raise-after)
  (check-equal? "Yo, a" (greet:text "a")))

(test "a buffer with no file evaluates its text as the REPL"
  (eval-test:scheme-buffer! "code.ss" "(define from-text (+ 1 2))\n")
  (check-equal? '("Evaluated the code.ss buffer" ()) (shown-after "C-c C-k"))
  (check-equal? 3 (eval:eval-text "from-text")))

(test "so does a buffer whose file does not exist yet, with its path's scope"
  (let ([fresh (eval-test:show! (files:visit (eval-test:home-path "fresh.ss")))])
    (buffers:insert! fresh 1 "(define fresh-value 4)\n")
    (check-equal? '("Evaluated the fresh.ss buffer" ()) (shown-after "C-c C-k"))
    (check-equal? (list 4 #f) (list (eval:eval-text "fresh-value") (file-exists? (eval-test:home-path "fresh.ss"))))))

(test "a plain library under a library root runs its body, then raises not a module"
  (eval-test:write-file! ".config/tuna/lib/plain.sls" "(library (plain) (export) (import (chezscheme)) (display \"body\"))\n")
  (eval-test:show! (files:visit (eval-test:home-path ".config/tuna/lib/plain.sls")))
  (check-equal? '("not a module with irritant (plain)" ((load-module! "not a module"))) (shown-after "C-c C-k"))
  (check-equal? '("body" "load-module!: not a module with irritant (plain)") (eval-test:log-tail 2)))
