(import (tuna) (test) (hooks) (options) (tables) (document) (buffers) (md) (kill-ring))

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

;; The ring offers no way to empty it, and a push with room for none
;; drops every entry.
(define (empty-ring!)
  (options:with ([kill-ring:max 0]) (kill-ring:push! (list ""))))

(define (pushed-during thunk)
  (let* ([pushed '()] [note (lambda (entry) (set! pushed (cons (kill-ring:text entry) pushed)))])
    (hooks:add! kill-ring:after-push note)
    (thunk)
    (hooks:remove! kill-ring:after-push note)
    (reverse pushed)))

(define (on-thread thunk)
  (let ([result #f])
    (join-task (fork-task (lambda (restore) (set! result (guard (c [(assertion-violation? c) c]) (thunk))))))
    result))

(test "an empty ring has no current entry and cannot rotate"
  (check-equal? #f (kill-ring:current))
  (check-equal? '() (kill-ring:entries))
  (check-raises (raised? 'kill-ring:rotate! "the kill ring is empty") (kill-ring:rotate! 1)))

(test "a push makes the newest entry, points the yank pointer at it, and calls after-push"
  (check-equal? '("a" "b" "c")
    (pushed-during (lambda () (for-each (lambda (s) (kill-ring:push! (list s))) '("a" "b" "c")))))
  (check-equal? '(("c") ("b") ("a")) (kill-ring:entries))
  (check-equal? '("c") (kill-ring:current))
  (empty-ring!))

(test "rotate! moves the yank pointer older, or newer for a negative count, around the ring"
  (for-each (lambda (s) (kill-ring:push! (list s))) '("a" "b" "c"))
  (check-equal? '(("b") ("a") ("c") ("a") ("b") ("b") ("c"))
    (let loop ([ns '(1 1 1 -1 5 0 -7)])
      (if (null? ns) '() (let ([e (kill-ring:rotate! (car ns))]) (cons e (loop (cdr ns)))))))
  (check-raises (raised? 'kill-ring:rotate! "not an exact integer") (kill-ring:rotate! 1.5))
  (check-raises (raised? 'kill-ring:rotate! "not an exact integer") (kill-ring:rotate! 1/2))
  (kill-ring:push! (list "d"))
  (check-equal? '("d") (kill-ring:current))
  (empty-ring!))

(test "an entry is a non-empty list of strings, pieces and kills"
  (for-each
    (lambda (v)
      (check-raises (raised? 'kill-ring:push! "not a non-empty list of strings, pieces and kills") (kill-ring:push! v)))
    (list '() "x" (list 1) (cons "a" "b") (list "a" 'b)))
  (check-raises (raised? 'kill-ring:append! "not a non-empty list of strings, pieces and kills") (kill-ring:append! '()))
  (check-raises (raised? 'kill-ring:prepend! "not a non-empty list of strings, pieces and kills") (kill-ring:prepend! (list #f)))
  (let ([p (buffers:piece (buffers:make "entry" "Hello\n") 1 3)])
    (for-each
      (lambda (entry)
        (check-raises (raised? 'kill-ring:text "not a non-empty list of strings and kills") (kill-ring:text entry)))
      (list '() "x" (list p)))))

(test "the ring keeps kill-ring:max entries, the oldest dropped; a lowered max drops them at the next push"
  (check-equal? 120 (kill-ring:max))
  (do ([i 0 (+ i 1)]) ((= i 130)) (kill-ring:push! (list (number->string i))))
  (let ([e (kill-ring:entries)])
    (check-equal? 120 (length e))
    (check-equal? '("129") (car e))
    (check-equal? '("10") (list-ref e 119)))
  (for-each (lambda (v) (check-raises assertion-violation? (options:set! kill-ring:max v))) (list -1 1.5 'x))
  (options:with ([kill-ring:max 3])
    (check-equal? 120 (length (kill-ring:entries)))
    (kill-ring:push! (list "x"))
    (check-equal? '(("x") ("129") ("128")) (kill-ring:entries))
    (check-equal? '("x") (kill-ring:rotate! 3)))
  (empty-ring!))

(test "with kill-ring:max 0 the ring keeps nothing, and after-push still gets each entry"
  (options:with ([kill-ring:max 0])
    (check-equal? '("gone" "also")
      (pushed-during (lambda () (kill-ring:push! (list "gone")) (kill-ring:append! (list "also")))))
    (check-equal? '() (kill-ring:entries))
    (check-equal? #f (kill-ring:current))))

(test "without kill-ring:skip-duplicates a push of the newest entry's text is another entry"
  (check-equal? '("d" "d") (pushed-during (lambda () (kill-ring:push! (list "d")) (kill-ring:push! (list "d")))))
  (check-equal? '(("d") ("d")) (kill-ring:entries))
  (empty-ring!))

(test "with kill-ring:skip-duplicates a push of the newest entry's text only moves the yank pointer, and after-push gets the newest"
  (options:with ([kill-ring:skip-duplicates #t])
    (let ([b (buffers:make "duplicates" "Hello world\n")])
      (kill-ring:push! (list "Hello"))
      (kill-ring:push! (list "older"))
      (kill-ring:push! (list "Hello"))
      (check-equal? '(("Hello") ("older") ("Hello")) (kill-ring:entries))
      (check-equal? '("older") (kill-ring:rotate! 1))
      (check-equal? '("Hello") (pushed-during (lambda () (kill-ring:push! (list (buffers:piece b 1 6))))))
      (check-equal? '("Hello") (kill-ring:current))
      (check-equal? 3 (length (kill-ring:entries)))
      (kill-ring:push! (list "Hello" "x"))
      (kill-ring:push! (list "Hello\nx"))
      (check-equal? 4 (length (kill-ring:entries)))
      (check-equal? '("Hello" "x") (kill-ring:current))
      (buffers:kill! b)))
  (empty-ring!))

(test "append! and prepend! join kill by kill onto the newest entry and point at it; with another number of kills, or none, they push"
  (check-equal? '("x") (begin (kill-ring:append! (list "x")) (kill-ring:current)))
  (empty-ring!)
  (check-equal? '("ab" "cd\n12" "cdef\n1234" "<cdef\n>1234" "single" "one single")
    (pushed-during
      (lambda ()
        (kill-ring:push! (list "ab"))
        (kill-ring:push! (list "cd" "12"))
        (check-equal? '("ab") (kill-ring:rotate! 1))
        (kill-ring:append! (list "ef" "34"))
        (check-equal? '("cdef" "1234") (kill-ring:current))
        (check-equal? '(("cdef" "1234") ("ab")) (kill-ring:entries))
        (kill-ring:prepend! (list "<" ">"))
        (check-equal? '("<cdef" ">1234") (kill-ring:current))
        (kill-ring:append! (list "single"))
        (check-equal? '(("single") ("<cdef" ">1234") ("ab")) (kill-ring:entries))
        (kill-ring:prepend! (list "one ")))))
  (check-equal? '(("one single") ("<cdef" ">1234") ("ab")) (kill-ring:entries))
  (empty-ring!))

(test "a kill's text joins its parts, an entry's joins its kills with line breaks"
  (check-equal? "alpha\nbeta" (kill-ring:text (list "alpha" "beta")))
  (let ([w (buffers:make "parts" (md:doc '() (md:para '() "One two.\n") (md:para '() "Three four.\n")))])
    (kill-ring:push! (list (buffers:piece w 6 17)))
    (kill-ring:append! (list "+"))
    (kill-ring:prepend! (list "<"))
    (check-equal? "<two.\nThre+" (kill-ring:text (kill-ring:current)))
    (buffers:kill! w))
  (empty-ring!))

(test "a kill keeps the texts its atoms' kinds gave when it was taken, and joins them with its characters on any thread"
  (let* ([b (buffers:make "atoms" (md:doc '() (md:para '() "a " (md:badge '((label . "NEW"))) " b " (md:image '()) "c\n")))]
         [p (buffers:piece b 2 10)])
    (check-equal? "a NEW b c" (buffers:piece-text p))
    (kill-ring:push! (list p))
    (let ([entry (kill-ring:current)])
      (set-box! md:badge-suffix "!")
      (check-equal? "a NEW! b c" (buffers:piece-text (buffers:piece b 2 10)))
      (check-equal? "a NEW b c" (kill-ring:text entry))
      (check-equal? "a NEW b c" (on-thread (lambda () (kill-ring:text entry))))
      (set-box! md:badge-suffix ""))
    (buffers:kill! b))
  (empty-ring!))

(test "duplicates are told by text, so a kill with atoms is one of a string with its text"
  (options:with ([kill-ring:skip-duplicates #t])
    (let ([b (buffers:make "atom-duplicates" (md:doc '() (md:para '() "a " (md:badge '((label . "NEW"))) " b\n")))])
      (kill-ring:push! (list (buffers:piece b 2 7)))
      (kill-ring:push! (list (kill-ring:text (kill-ring:current))))
      (check-equal? 1 (length (kill-ring:entries)))
      (buffers:kill! b)))
  (empty-ring!))

(test "join makes one kill of strings, pieces and kills: pushed, it is one entry and one call of after-push"
  (let ([w (buffers:make "cells" (md:doc '() (md:para '() "One two.\n") (md:para '() "Three four.\n")))])
    (check-equal? '("One|Three")
      (pushed-during (lambda () (kill-ring:push! (list (kill-ring:join (buffers:piece w 2 5) "|" (buffers:piece w 13 18)))))))
    (check-equal? 1 (length (kill-ring:current)))
    (check-equal? "One|Three" (kill-ring:text (kill-ring:current)))
    (buffers:kill! w))
  (check-equal? "" (kill-ring:join))
  (check-equal? "abc" (kill-ring:text (list (kill-ring:join "a" (kill-ring:join "b" "c")))))
  (check-raises (raised? 'kill-ring:join "not a string, a piece or a kill") (kill-ring:join 'x))
  (empty-ring!))

(test "a piece pushed is kept as a kill, which prints as #<kill>"
  (let ([b (buffers:make "printed" "Buy milk.\n")])
    (kill-ring:push! (list "first"))
    (buffers:with-buffer b
      (kill-ring:push! (list (buffers:piece (buffers:current) 1 6))))
    (check-equal? "((#<kill>) (\"first\"))" (format "~s" (kill-ring:entries)))
    (check-equal? "Buy m" (kill-ring:text (kill-ring:current)))
    (buffers:kill! b))
  (empty-ring!))

(test "the procedures that change the ring raise on another thread; reading it works on any"
  (kill-ring:push! (list "first"))
  (let ([b (buffers:make "threads" "Hello world\n")])
    (for-each
      (lambda (who thunk)
        (check-equal? (list who "not on the main thread")
          (let ([c (on-thread thunk)]) (list (condition-who c) (condition-message c)))))
      '(kill-ring:push! kill-ring:append! kill-ring:prepend! kill-ring:rotate! kill-ring:join kill-ring:insert!)
      (list (lambda () (kill-ring:push! (list "x")))
            (lambda () (kill-ring:append! (list "x")))
            (lambda () (kill-ring:prepend! (list "x")))
            (lambda () (kill-ring:rotate! 1))
            (lambda () (kill-ring:join "x"))
            (lambda () (kill-ring:insert! b 1 "x"))))
    (check-equal? '("first") (on-thread kill-ring:current))
    (check-equal? '(("first")) (on-thread kill-ring:entries))
    (check-equal? "Hello\ntwo" (on-thread (lambda () (kill-ring:text (list "Hello" "two")))))
    (check-equal? '(("first")) (kill-ring:entries))
    (check-equal? "Hello world\n" (document:text (buffers:document b)))
    (buffers:kill! b))
  (empty-ring!))

(test "the options, hook and table are documented"
  (check-equal? "How many entries the ring keeps; pushing one more drops the oldest." (options:documentation kill-ring:max))
  (check-equal? "When true, pushing an entry whose text equals the newest entry's only moves the yank pointer to the newest."
    (options:documentation kill-ring:skip-duplicates))
  (check-equal? "Called with the newest entry after each push!, append! and prepend!." (hooks:documentation kill-ring:after-push))
  (check (string? (tables:documentation kill-ring:yankers))))
