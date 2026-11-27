(import (tuna) (test) (test-runner) (modes) (buffers) (document) (views) (jobs) (options) (tables) (syntax-highlighting)
        (buffers-test) (test-user) (syntax-highlighting-test) (syntax-highlighting-test marks))

(define marked syntax-highlighting-test:marked)
(define faces-become syntax-highlighting-test/marks:faces-become)
(define parens-become syntax-highlighting-test/marks:parens-become)
(define inputs-become syntax-highlighting-test/marks:inputs-become)
(define take-inputs! syntax-highlighting-test/marks:inputs)
(define job-events syntax-highlighting-test:job-events)

(jobs:define-worker (worker input emit receive) (void))

(define (input buffer data) #f)

(test "make-highlighter checks its worker, its layer types and its input procedure"
  (check (syntax-highlighting:highlighter? (tables:ref syntax-highlighting:highlighters "marks" #f)))
  (check (syntax-highlighting:highlighter? (syntax-highlighting:make-highlighter worker (list syntax-highlighting:faces) input)))
  (check-equal? #f (syntax-highlighting:highlighter? worker))
  (check-raises (buffers-test:raised-with? 'syntax-highlighting:make-highlighter "not a worker" '(w))
                (syntax-highlighting:make-highlighter 'w (list syntax-highlighting:faces) input))
  (check-raises (buffers-test:raised-with? 'syntax-highlighting:make-highlighter "not a list of layer types" '(()))
                (syntax-highlighting:make-highlighter worker '() input))
  (check-raises (buffers-test:raised-with? 'syntax-highlighting:make-highlighter "not a list of layer types" '((1)))
                (syntax-highlighting:make-highlighter worker (list 1) input))
  (check-raises (buffers-test:raised-with? 'syntax-highlighting:make-highlighter "not a procedure" '(input))
                (syntax-highlighting:make-highlighter worker (list syntax-highlighting:faces) 'input)))

(test "the face layer: text inserted right after a span takes its face"
  (let ([b (buffers:make "layer" "ab")])
    (buffers:set-spans! (buffers:layer b syntax-highlighting:faces) 0 1 '((0 1 ((face . comment)))))
    (buffers:insert! b 1 "x")
    (check-equal? '((0 2 ((face . comment)))) (buffers:spans (buffers:layer b syntax-highlighting:faces) 0 3))))

(define a (buffers:make "a.mk" "#one two (#three)\n"))

(test "a buffer gets its job at the end of the batch its mode is set in, so a view made in that batch is there for the input"
  (take-inputs!)
  (job-events)
  (modes:set-major-mode syntax-highlighting-test/marks:mode a)
  (views:make a)
  (check-equal? '() (take-inputs!))
  (faces-become a '(("#one" comment) ("#three" comment)))
  (parens-become a '("(" ")"))
  (check-equal? '((start %marks)) (job-events)))

(test "the input procedure runs with no data when the job starts, then with the data the job returns"
  (inputs-become '(("a.mk" #f 1) ("a.mk" (1 ()) 1)))
  (take-inputs!))

(test "each edit goes to the job, which highlights the newest text and is told each edit: start, removed, inserted"
  (buffers:replace! a 6 9 "#2")
  (buffers:insert! a 5 "x")
  (faces-become a '(("#onex" comment) ("#2" comment) ("#three" comment)))
  (inputs-become '(("a.mk" (2 ((5 3 2) (4 0 1))) 1)))
  (take-inputs!))

(test "text typed right after a span takes its face until the job answers"
  (buffers:insert! a 6 "!")
  (check-equal? '((1 7 ((face . comment)))) (buffers:spans (buffers:layer a syntax-highlighting:faces) 0 8))
  (faces-become a '(("#onex!" comment) ("#2" comment) ("#three" comment)))
  (inputs-become '(("a.mk" (3 ((5 0 1))) 1)))
  (take-inputs!))

(test "update! calls the input procedure again and sends a changed input; an unchanged one is not sent, so the job does not run"
  (buffers:with-buffer a (options:set-local! syntax-highlighting-test/marks:mark "x"))
  (syntax-highlighting:update! a)
  (faces-become a '())
  (inputs-become '(("a.mk" (3 ((5 0 1))) 1) ("a.mk" (4 ()) 1)))
  (take-inputs!)
  (syntax-highlighting:update! a)
  (check-equal? '(("a.mk" (4 ()) 1)) (take-inputs!)))

(define b (marked "b.mk" "#b x" syntax-highlighting-test/marks:mode))

(test "without a buffer, update! reads the input of every buffer with a job"
  (faces-become b '(("#b" comment)))
  (check-equal? '((start %marks)) (job-events))
  (inputs-become '(("b.mk" #f 0) ("b.mk" (1 ()) 0)))
  (take-inputs!)
  (buffers:with-buffer a (options:set-local! syntax-highlighting-test/marks:mark "#"))
  (buffers:with-buffer b (options:set-local! syntax-highlighting-test/marks:mark "x"))
  (syntax-highlighting:update!)
  (faces-become a '(("#onex!" comment) ("#2" comment) ("#three" comment)))
  (faces-become b '(("x" comment)))
  (test-runner:wait-until (lambda () (= 4 (syntax-highlighting-test/marks:inputs-count))))
  (check-equal? '(("a.mk" (4 ()) 1) ("a.mk" (5 ()) 1) ("b.mk" (1 ()) 0) ("b.mk" (2 ()) 0))
                (list-sort (lambda (x y) (string<? (car x) (car y))) (take-inputs!)))
  (check-raises (buffers-test:raised-with? 'syntax-highlighting:update! "not a buffer" '(a)) (syntax-highlighting:update! 'a)))

(test "input-changed! reads a running job's input again and sends it only when it changed"
  (buffers:with-buffer a (options:set-local! syntax-highlighting-test/marks:mark "x"))
  (syntax-highlighting:input-changed! a)
  (faces-become a '())
  (inputs-become '(("a.mk" (5 ()) 1) ("a.mk" (6 ()) 1)))
  (take-inputs!)
  (syntax-highlighting:input-changed! a)
  (check-equal? '(("a.mk" (6 ()) 1)) (take-inputs!))
  (buffers:with-buffer a (options:set-local! syntax-highlighting-test/marks:mark "#"))
  (syntax-highlighting:input-changed! a)
  (faces-become a '(("#onex!" comment) ("#2" comment) ("#three" comment)))
  (inputs-become '(("a.mk" (6 ()) 1) ("a.mk" (7 ()) 1)))
  (take-inputs!)
  (check-raises (buffers-test:raised-with? 'syntax-highlighting:input-changed! "not a buffer" '(a))
                (syntax-highlighting:input-changed! 'a)))

(define d (marked "d" "#d (x)" syntax-highlighting-test/marks:derived))

(define o (marked "o" "#o !own" syntax-highlighting-test/marks:own))

(test "a buffer's highlighter is its ancestry's first entry, else its language's: a derived mode uses its parent's language, a mode's own entry wins"
  (faces-become d '(("#d" comment)))
  (faces-become o '(("!own" comment)))
  (check-equal? '((start %marks) (start %marks)) (job-events)))

(test "a mode with no language, or a language with no highlighter, gets no job and no message"
  (let ([u #f] [n #f])
    (check-equal? '()
                  (test-runner:reports-during
                    (lambda ()
                      (set! u (marked "u" "#u" syntax-highlighting-test/marks:unnamed))
                      (set! n (marked "n" "#n" syntax-highlighting-test/marks:unknown)))))
    (check-equal? "nothing" (modes:language syntax-highlighting-test/marks:unknown))
    (check-equal? '(() ()) (list (syntax-highlighting-test/marks:faces u) (syntax-highlighting-test/marks:faces n)))
    (check-equal? '() (job-events))))

(test "a buffer whose mode changes to one without a highlighter loses its job and its spans"
  (modes:set-major-mode modes:fundamental d)
  (faces-become d '())
  (parens-become d '())
  (check-equal? '((stop %marks)) (job-events)))

(test "setting a buffer's mode again restarts its job, which reads its input anew"
  (take-inputs!)
  (modes:set-major-mode syntax-highlighting-test/marks:mode b)
  (faces-become b '(("#b" comment)))
  (inputs-become '(("b.mk" #f 0) ("b.mk" (1 ()) 0)))
  (take-inputs!)
  (check-equal? '((stop %marks) (start %marks)) (job-events)))

(test "killing a buffer stops its job"
  (buffers:kill! o)
  (test-user:settle)
  (check-equal? '((stop %marks)) (job-events)))

(define r (marked "r" "#r" syntax-highlighting-test/marks:raising))

(test "a job that raises is reported and leaves its buffer no spans and no job, until update! starts one, or its mode changes"
  (faces-become r '(("#r" comment)))
  (check-equal? '((start %raising)) (job-events))
  (check-equal? '((marks "the highlighter raised"))
                (syntax-highlighting-test:reports-until 1 (lambda () (buffers:insert! r 3 "!"))))
  (faces-become r '())
  (check-equal? '((marks "the highlighter raised"))
                (syntax-highlighting-test:reports-until 1 (lambda () (syntax-highlighting:update! r))))
  (check-equal? '() (syntax-highlighting-test/marks:faces r))
  (check-equal? '((start %raising)) (job-events))
  (modes:set-major-mode syntax-highlighting-test/marks:mode r)
  (faces-become r '(("#r!" comment)))
  (check-equal? '((start %marks)) (job-events)))

(test "an input procedure that raises is reported, and the job stops with it; update! tries again, input-changed! does not"
  (take-inputs!)
  (buffers:with-buffer r (options:set-local! syntax-highlighting-test/marks:input-raises? #t))
  (check-equal? '((marks:input "the input raised"))
                (syntax-highlighting-test:reports-until 1 (lambda () (syntax-highlighting:update! r))))
  (faces-become r '())
  (check-equal? '((stop %marks)) (job-events))
  (check-equal? '((marks:input "the input raised"))
                (syntax-highlighting-test:reports-until 1 (lambda () (syntax-highlighting:update! r))))
  (check-equal? '() (job-events))
  (check-equal? '() (test-runner:reports-during (lambda () (syntax-highlighting:input-changed! r) (test-user:settle))))
  (check-equal? '() (job-events))
  (buffers:with-buffer r (options:set-local! syntax-highlighting-test/marks:input-raises? #f))
  (syntax-highlighting:update! r)
  (faces-become r '(("#r!" comment)))
  (check-equal? '((start %marks)) (job-events)))

(test "a value of another shape raises in the job: not a list of spans for each layer, not a layer's spans"
  (let ([bad (buffers:make "bad" "x")])
    (check-equal? '((serve "not a list of spans for each layer"))
                  (syntax-highlighting-test:reports-until 1 (lambda () (modes:set-major-mode syntax-highlighting-test/marks:misshapen bad))))
    (buffers:with-buffer bad (options:set-local! syntax-highlighting-test/marks:shape "not a layer's spans"))
    (check-equal? '((serve "not a layer's spans"))
                  (syntax-highlighting-test:reports-until 1 (lambda () (syntax-highlighting:update! bad))))))

(test "an entry that is not a highlighter is reported when a buffer would start a job with it"
  (let ([odd (buffers:make "odd" "x")])
    (tables:set! syntax-highlighting:highlighters syntax-highlighting-test/marks:unnamed 'nothing)
    (check-equal? 1 (length (syntax-highlighting-test:reports-until 1
                              (lambda () (modes:set-major-mode syntax-highlighting-test/marks:unnamed odd)))))
    (tables:remove! syntax-highlighting:highlighters syntax-highlighting-test/marks:unnamed)))

(test "update! and input-changed! are for the main thread"
  (check-equal? '(syntax-highlighting:update! "not on the main thread") (buffers-test:on-thread (lambda () (syntax-highlighting:update! a))))
  (check-equal? '(syntax-highlighting:input-changed! "not on the main thread")
                (buffers-test:on-thread (lambda () (syntax-highlighting:input-changed! a)))))
