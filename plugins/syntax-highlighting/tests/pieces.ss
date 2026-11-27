(import (tuna) (test) (test-runner) (modes) (buffers) (options) (timers) (syntax-highlighting) (syntax-highlighting-test)
        (syntax-highlighting-test marks))

(define faces syntax-highlighting-test/marks:faces)
(define faces-become syntax-highlighting-test/marks:faces-become)
(define inputs-become syntax-highlighting-test/marks:inputs-become)

(define (gates name) (string-append (getenv "HOME") "/gates/" name))

(mkdir (string-append (getenv "HOME") "/gates"))

(define (pieces-buffer name content)
  (mkdir (gates name))
  (syntax-highlighting-test:marked name content syntax-highlighting-test/marks:pieces))

(define (open-gate! b n)
  (call-with-output-file (string-append (gates (buffers:name b)) "/gate-" (number->string n)) (lambda (p) (void))))

(test "a highlighter may answer in pieces: the job sets each piece as it comes and takes newer edits between them"
  (let ([p (pieces-buffer "p" "#a b\n#c d\n#e f\n")])
    (open-gate! p 1)
    (faces-become p '(("#a" comment)))
    (buffers:insert! p 2 "x")
    (open-gate! p 2)
    (faces-become p '(("#xa" comment) ("#c" comment)))
    (open-gate! p 3)
    (inputs-become '(("p" #f) ("p" (1 0 ())) ("p" (2 1 ())) ("p" (3 0 ((1 0 1))))))
    (check-equal? '(("#xa" comment) ("#c" comment)) (faces p))
    (open-gate! p 4)
    (open-gate! p 5)
    (faces-become p '(("#xa" comment) ("#c" comment) ("#e" comment)))
    (inputs-become '(("p" #f) ("p" (1 0 ())) ("p" (2 1 ())) ("p" (3 0 ((1 0 1)))) ("p" (4 1 ())) ("p" (5 2 ()))))
    (syntax-highlighting-test/marks:inputs)))

(test "when the buffer's log no longer holds the version an answer was for, the job sends every span it holds again, moved to the newest version"
  (let ([q (pieces-buffer "q" "#a\n#b\n#c\n")])
    (open-gate! q 1)
    (faces-become q '(("#a" comment)))
    (do ([i 0 (+ i 1)]) ((= i 1001)) (buffers:insert! q 1 "\n"))
    (timers:set-idle! #t)
    (test-runner:wait-until (lambda () (not (buffers:edits-since q 0))))
    (timers:set-idle! #f)
    (open-gate! q 2)
    (open-gate! q 3)
    (faces-become q '(("#a" comment) ("#b" comment)))))

(test "a ranged answer is cut to its range: of spans reaching outside it, only their part inside is set"
  (let ([r (syntax-highlighting-test:marked "r" "#abcd #ef\n" syntax-highlighting-test/marks:ranged)])
    (buffers:with-buffer r (options:set-local! syntax-highlighting-test/marks:range '(0 3)))
    (syntax-highlighting:update! r)
    (faces-become r '(("#ab" comment)))
    (buffers:with-buffer r (options:set-local! syntax-highlighting-test/marks:range '(4 8)))
    (syntax-highlighting:update! r)
    (faces-become r '(("#ab" comment) ("d" comment) ("#e" comment)))))
