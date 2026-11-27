(import (tuna) (test) (eval-test caught-reports) (test-user) (options) (buffers) (views) (layout) (layout-split) (editing) (echo-area) (undo)
        (minibuffer) (completion) (files) (chez-scheme) (chez-scheme-completion) (eval) (eval-test))

(define (message) (echo-area:current-message))

(define notes (eval-test:show! (buffers:make "notes" "alpha\n")))

(eval-test:at! notes "alpha" 5)

(define (shown-value text)
  (eval-test:eval! text #f)
  (message))

(test "the page's example: values show one per line in the echo area"
  (eval:expression "(values 1 \"two\")" #f)
  (check-equal? "1\n\"two\"" (message)))

(test "show-result writes each value but void, one per line"
  (check-equal? "42\n\"two\""
    (call-with-string-output-port (lambda (p) (eval:show-result p (list 42 (void) "two"))))))

(test "arguments are checked where they cross into the plugin"
  (check-raises assertion-violation? (eval:show-result 'port '()))
  (check-raises assertion-violation? (eval:region (buffers:make "r" "1") 0 9))
  (check-raises assertion-violation? (eval:buffer "notes"))
  (check-raises assertion-violation? (eval:expression 'x #f)))

(test "M-: reads one expression at the prompt Eval:, evaluates it, and shows its value in the echo area and the log; text, point, views and the selection stay; the history gains the input"
  (let ([before (list (layout:views) (eval-test:view))])
    (test-user:press! "M-:")
    (check-equal? "Eval: \n" (eval-test:prompt-text))
    (check (not (eq? notes (views:buffer (eval-test:view)))))
    (test-user:type! "(+ 1 2)")
    (test-user:press! "RET")
    (check-equal? (list #f "3" '("3") "alpha|\n" before '("(+ 1 2)"))
      (list (eval-test:prompt) (message) (eval-test:log-tail 1) (test-user:text) (list (layout:views) (eval-test:view))
            (eval:expression-history)))))

(test "a string is written with its quotes"
  (check-equal? "\"hi\"" (shown-value "\"hi\"")))

(test "lists and vectors are shortened to eval:print-length elements and eval:print-level levels, 12 and 4 by default; strings never are"
  (check-equal? "(a a a a a a a a a a a a ...)" (shown-value "(make-list 30 'a)"))
  (check-equal? "(1 (2 (3 (4 (...)))))" (shown-value "'(1 (2 (3 (4 (5)))))"))
  (check-equal? "#(1 #(2 #(3 #(4 #(...)))))" (shown-value "'#(1 #(2 #(3 #(4 #(5)))))"))
  (check-equal? 302 (string-length (shown-value "(make-string 300 #\\x)"))))

(test "with C-u or any prefix but -, the value is inserted at point in full as one edit, and the echo area and log are left as they were"
  (let ([before (list (message) (eval-test:log-tail 1000))])
    (eval-test:eval! "(+ 1 2)" "C-u")
    (check-equal? (list "alpha3|\n" #f (cadr before)) (list (test-user:text) (message) (eval-test:log-tail 1000))))
  (test-user:press! "C-/")
  (check-equal? "alpha|\n" (test-user:text))
  (eval-test:eval! "(make-list 30 'a)" "C-u")
  (check-equal? "alpha(a a a a a a a a a a a a a a a a a a a a a a a a a a a a a a)|\n" (test-user:text))
  (test-user:press! "C-/")
  (eval-test:eval! "(+ 1 2)" "M-5")
  (check-equal? "alpha3|\n" (test-user:text))
  (test-user:press! "C-/")
  (eval-test:eval! "(+ 1 2)" "M--")
  (check-equal? '("3" "alpha|\n") (list (message) (test-user:text))))

(test "what the expression writes and the messages it shows are logged in order, the screen showing the last"
  (eval-test:eval! "(begin (display \"out\") (echo-area:message! \"msg\") 42)" #f)
  (check-equal? '("42" ("out" "msg" "42")) (list (message) (eval-test:log-tail 3))))

(test "writes after the last message join one message, and the value follows them"
  (eval-test:eval! "(begin (display \"out\") 7)" #f)
  (check-equal? '("out7" ("42" "out7")) (list (message) (eval-test:log-tail 2))))

(test "the key that starts the next M-: ends the printed message, so two equal prints log twice, and a later message makes the second a repeat"
  (eval-test:eval! "(begin (display \"a\") (void))" #f)
  (check-equal? "a" (message))
  (eval-test:eval! "(begin (display \"a\") (void))" #f)
  (check-equal? '("a" ("a" "a")) (list (message) (eval-test:log-tail 2)))
  (echo-area:message! "m")
  (check-equal? '("a [2 times]" "m") (eval-test:log-tail 2)))

(test "an error is reported: the echo area shows its message in the error face, the log its who too; no view opens, and the history keeps the input"
  (let ([views-before (layout:views)])
    (check-equal? '((car "~s is not a pair")) (eval-test:reports-during (lambda () (eval-test:eval! "(car 1)" #f))))
    (check-equal? (list "1 is not a pair" 'error '("car: 1 is not a pair") views-before "(car 1)")
      (list (message) (echo-area:current-face) (eval-test:log-tail 1) (layout:views) (car (eval:expression-history))))))

(test "what was written before the error is logged before the report"
  (check-equal? '((car "~s is not a pair"))
    (eval-test:reports-during (lambda () (eval-test:eval! "(begin (display \"before\") (car 1))" #f))))
  (check-equal? '("1 is not a pair" ("before" "car: 1 is not a pair")) (list (message) (eval-test:log-tail 2))))

(define x 0)

(test "a definition shows the name it defines and defines it as the REPL; with C-u the name is inserted"
  (eval-test:eval! "(define x 1)" #f)
  (check-equal? '("x" 1) (list (message) x))
  (eval-test:eval! "(define x 2)" "C-u")
  (check-equal? '("alphax|\n" 2) (list (test-user:text) x))
  (test-user:press! "C-/"))

(test "the current input port is empty while it runs, so a read sees the end of file at once"
  (check-equal? "#!eof" (shown-value "(read)")))

(test "several values show one per line; void is left out, and with no value and no output the echo area says so"
  (check-equal? "1\n\"two\"" (shown-value "(values 1 \"two\" (void))"))
  (check-equal? "No value" (shown-value "(void)"))
  (check-equal? "No value" (shown-value "(values)")))

(test "a cyclic value is written with labels"
  (check-equal? "#0=(1 2 . #0#)" (shown-value "(let ([x (list 1 2)]) (set-cdr! (cdr x) x) x)")))

(test "with eval:print-length #f lists are written whole, and a large value is one message and one log line"
  (options:set! eval:print-length #f)
  (check-equal? "(a a a a a a a a a a a a a a a a a a a a a a a a a a a a a a)" (shown-value "(make-list 30 'a)"))
  (let ([m (shown-value "(iota 100000)")])
    (check-equal? '(588891 "(0 1 2" "99999)") (list (string-length m) (substring m 0 6) (substring m (- (string-length m) 6) (string-length m))))
    (check-equal? 588891 (string-length (car (eval-test:log-tail 1)))))
  (options:unset! eval:print-length))

(test "each result is logged, and an equal one counts on the last line"
  (eval-test:eval! "(+ 1 2)" #f)
  (eval-test:eval! "(+ 1 2)" #f)
  (test-user:press! "C-a")
  (check-equal? '("3 [2 times]") (eval-test:log-tail 1)))

(test "a form is a definition when its head, after any prefix, is define or starts with define-, and its values are only void"
  (check-equal? "greeting" (shown-value "(define (greeting n) n)"))
  (check-equal? "point" (shown-value "(define-record-type (point make-point point?) (fields x))"))
  (check-equal? "say-hello" (shown-value "(commands:define-command (say-hello) \"Says hello.\" (echo-area:message! \"Hello\"))"))
  (check-equal? "5" (shown-value "(begin (define y 1) 5)")))

(eval-test:write-greet!)

(import (greet))

(test "M-: evaluates as the REPL in a module's file too, where the module's names have their prefix"
  (eval-test:show! (files:visit (eval-test:home-path ".config/tuna/lib/greet.sls")))
  (check-equal? '((#f "variable ~:s is not bound"))
    (eval-test:reports-during (lambda () (eval-test:eval! "(text \"a\")" #f))))
  (check-equal? "variable text is not bound" (message))
  (check-equal? "\"Hello, a!\"" (shown-value "(greet:text \"a\")")))
