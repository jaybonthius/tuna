(import (tuna) (test) (test-runner) (processes))

(define (home-of name) (string-append (getenv "HOME") "/" name))

(define (data-in text)
  (let ([p (open-input-string text)])
    (let loop ([acc '()])
      (let ([d (read p)])
        (if (eof-object? d) (reverse acc) (loop (cons d acc)))))))

(define (recorded home name)
  (let ([path (string-append home "/" name)])
    (if (file-exists? path) (data-in (call-with-input-file path get-string-all)) '())))

(define (options home)
  (processes:options [directory home] [environment (test-runner:home-environment home)] [separate-stderr #t]))

(define (console-run name input)
  (let ([home (home-of name)])
    (test-runner:make-home! home "console/init.ss")
    (let-values ([(status output errors) (processes:run (car (command-line)) '() input (options home))])
      (values status (utf8->string output) (utf8->string errors) home))))

(test "each value is written on a line of its own, after a fresh line, and the void value writes nothing"
  (let-values ([(status output errors home)
                (console-run "values" "(define x 5)\n(values x \"five\")\n(if #f #f)\n(begin (display \"partial\") 'after)\n")])
    (check-equal? 0 status)
    (check-equal? "" errors)
    (check-equal? "5\n\"five\"\npartial\nafter\n" output)))

(test "a form runs as the REPL, and the next is read once it has ended, pauses included; a line may hold several"
  (let-values ([(status output errors home)
                (console-run "order" "(begin (timers:sleep 0.1) 'first) 'second\n(owner-name (current-owner))\n")])
    (check-equal? 0 status)
    (check-equal? "" errors)
    (check-equal? '(first second (repl)) (data-in output))))

(test "a form that raises is reported, and the console reads the next"
  (let-values ([(status output errors home) (console-run "raises" "(error 'check \"bad value\" 7)\n'next\n")])
    (check-equal? 0 status)
    (check-equal? "" errors)
    (check-equal? '(next) (data-in output))
    (check-equal? '((check "bad value" (7))) (recorded home "reports"))))

(test "a read error is reported, and reading goes on after the characters that failed"
  (let-values ([(status output errors home) (console-run "read-error" "#< 'after\n")])
    (check-equal? 0 status)
    (check-equal? "" errors)
    (check-equal? '(after) (data-in output))
    (check-equal? '(read) (map car (recorded home "reports")))))

(test "the console starts reading when the configuration's task pauses, so a form runs while a later form of the configuration waits"
  (let-values ([(status output errors home)
                (console-run "paused" "(getprop 'console-test 'phase)\n(begin (timers:sleep 1) (getprop 'console-test 'phase))\n")])
    (check-equal? 0 status)
    (check-equal? '(paused resumed) (data-in output))))

(test "forms are read back as the same data, whatever the printer's settings"
  (let-values ([(status output errors home)
                (console-run "printer"
                  "(print-length 2)\n(length (list 1 2 3 4 5))\n(print-length #f)\n(gensym? '#{g1 console-test})\n(let ([v '#0=(a . #0#)]) (eq? v (cdr v)))\n")])
    (check-equal? 0 status)
    (check-equal? '(5 #t #t) (data-in output))))

(test "reloading the console keeps its place in standard input"
  (let-values ([(status output errors home) (console-run "reload" "(reload-modules! '((console))) 'after-reload\n'next\n")])
    (check-equal? 0 status)
    (check-equal? "" errors)
    (check-equal? '(after-reload next) (data-in output))))

(test "unloading the console ends its instance's reading; the configuration, which imports it, loads a new one that reads on"
  (let-values ([(status output errors home)
                (console-run "unload"
                  "(define old (module-owner '(console)))\n(unload-owner! old)\n(list (owner-live? old) (eq? old (module-owner '(console))))\n'next\n")])
    (check-equal? 0 status)
    (check-equal? "" errors)
    (check-equal? '((#f #f) next) (data-in output))))

(test "at the end of input the console exits: the configuration is unloaded, and Tuna exits with status 0, or the status exit gives"
  (let-values ([(status output errors home) (console-run "end" "'last\n")])
    (check-equal? 0 status)
    (check-equal? '(last) (data-in output))
    (check-equal? '(configuration) (recorded home "unloaded")))
  (let-values ([(status output errors home) (console-run "exit" "(exit 3)\n'never\n")])
    (check-equal? 3 status)
    (check-equal? "" output)
    (check-equal? '(configuration) (recorded home "unloaded"))))

(test "Ctrl-C, with no handler registered, exits Tuna, which unloads every plugin"
  (let* ([home (home-of "interrupted")] [status #f] [output '()])
    (test-runner:make-home! home "console/init.ss")
    (let ([process (processes:start (car (command-line)) '()
                     (lambda (bytes end) (unless (eof-object? bytes) (set! output (cons (utf8->string bytes) output))))
                     (lambda (s) (set! status s))
                     (options home))])
      (processes:send! process "'ready\n")
      (test-runner:wait-until (lambda () (pair? output)))
      (processes:signal! process (processes:signal int))
      (test-runner:wait-until (lambda () status))
      (check-equal? 0 status)
      (check-equal? '(configuration) (recorded home "unloaded")))))
