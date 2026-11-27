(import (tuna) (test) (modes) (buffers) (document) (syntax) (chez-scheme) (syntax-test) (chez-scheme-test scheme-buffers))

(define scheme-buffer chez-scheme-test/scheme-buffers:scheme-buffer)
(define after syntax-test:after)
(define before syntax-test:before)
(define between syntax-test:between)

(define (sexps b from)
  (let loop ([at from] [acc '()])
    (let ([end (syntax:sexp-after b at)])
      (if end
          (loop end (cons (between b (syntax:sexp-before b end) end) acc))
          (reverse acc)))))

(define (form b position . mode)
  (call-with-values (lambda () (apply syntax:top-level-form b position mode))
    (lambda (s e) (and s (between b s e)))))

(define (opening-texts b position mode)
  (map (lambda (o) (between b (syntax:lexeme-start o) (syntax:lexeme-end o))) (syntax:openings b position mode)))

(test "a sexp is an atom, a string or a list with the prefixes before it, and comments may come between a prefix and what follows"
  (check-equal? '("f" "'x" "' ; note\n (h)" "\"s\"" "#(1)" "." "y")
                (sexps (scheme-buffer "sexps.ss" "(f 'x #;(g) ' ; note\n (h) \"s\" #(1) . y)") 2)))

(define t (scheme-buffer "t.ss" "(define (greet name) (string-append \"Hi \" name))\n(greet \"you\")\n"))

(test "inside a symbol sexp-before gives its start; between sexps the one before; at a list's start nothing"
  (check-equal? '(10 9 2 23) (map (lambda (p) (syntax:sexp-before t p)) (list (after t "(gre") (after t "name)") (after t "(def") (after t "(string-append "))))
  (check-equal? 2 (syntax:sexp-before t (after t "(define")))
  (check-equal? #f (syntax:sexp-before t (before t "define"))))

(test "the sexp that starts at a position ends at sexp-after of it"
  (check-equal? 63 (syntax:sexp-after t (before t "(greet \"you"))))

(test "the lists holding a position, outermost first, from the end of each opening to the start of its match"
  (check-equal? '(1 22) (map syntax:lexeme-start (syntax:openings t (after t "Hi "))))
  (check-equal? '((open 1 2 1)) (map syntax-test:lexeme->list (syntax:openings t (before t "(string"))))
  (check-equal? '() (syntax:openings t (after t "name))"))))

(test "an unmatched list holds every position after its opening, as Emacs's syntax-ppss counts it"
  (let ([u (scheme-buffer "u.ss" "(a (b c\n")])
    (check-equal? '(1 4) (map syntax:lexeme-start (syntax:openings u 8)))
    (check-equal? '(1 4) (map syntax:lexeme-start (syntax:openings u 9)))))

(test "comments are not sexps: inside one, the sexps are those around it"
  (let ([m (scheme-buffer "m.ss" "(a ; (b c)\n d)\n#| (e) |#\n(f)\n")])
    (check-equal? (list 14 1 'comment)
                  (list (syntax:sexp-after m (after m "(b")) (length (syntax:openings m (after m "(b")))
                        (syntax:lexeme-class (syntax:lexeme-at m (after m "(b")))))
    (check-equal? "(f)" (form m (after m "(e")))))

(test "except for sexp-before: inside a ; or #| comment the text from its first whitespace or opening bracket reads as code"
  (let* ([e (scheme-buffer "e.ss" "(define x 1)\n;; (greet:text \"x\")\n#|(f (g y)|#\n#;(h (i z) w)\n;; done\n")]
         [before-text (lambda (position) (between e (syntax:sexp-before e position) position))])
    (check-equal? "(greet:text \"x\")" (before-text (after e "\"x\")")))
    (check-equal? "\"x\"" (before-text (after e "\"x\"")))
    (check-equal? "(g y)" (before-text (after e "(g y)")))
    (check-equal? "(i z)" (before-text (after e "(i z)")))
    (check-equal? "done" (before-text (after e ";; done")))
    (check-equal? 1 (syntax:sexp-before e (after e ";; ")))))

(define words (apply string-append (map (lambda (k) (format "w~a\n" k)) (iota 40))))

(test "a lexer not the buffer's own reads from the last line at or above that starts with an opening bracket, so a lone \" in prose above hides nothing"
  (let ([p (buffers:make "notes" "He said \"hi.\n(define (f) 1)\n(f)\n")] [q (scheme-buffer "q.ss" "He said \"hi.\n(define (f) 1)\n(f)\n")])
    (check-equal? modes:fundamental (modes:major-mode p))
    (check-equal? 29 (syntax:sexp-before p (after p "1)\n(f)") chez-scheme:mode))
    (check-equal? "(define (f) 1)" (form p (after p "(defi") chez-scheme:mode))
    (check-equal? 9 (syntax:sexp-before q (after q "1)\n(f)")))))

(test "the line found may be far above, with prefix syntax before its bracket; a line a string runs into still counts when it starts with a bracket"
  (let ([r (buffers:make "long notes" (string-append "He said \"hi.\n#(outer\n" words "say \"hi\n(g x\nlast\n"))])
    (check-equal? '("#(") (opening-texts r (after r "w30") chez-scheme:mode))
    (check-equal? '("(") (opening-texts r (after r "las") chez-scheme:mode))
    (check-equal? (- (after r "(g") 2) (syntax:lexeme-start (car (syntax:openings r (after r "las") chez-scheme:mode))))))

(test "with no such line at or above, the lexer reads from the position's own line"
  (let ([u (buffers:make "prose" (string-append "He said \"hi\n" words "see (editing:forward-word b) here\n"))])
    (check-equal? '("(") (opening-texts u (after u "forward-word b") chez-scheme:mode))
    (check-equal? "(editing:forward-word b)" (form u (after u "forward-word b") chez-scheme:mode))))

(test "a top-level form: no list holds it, or its opening is in column 0, which ends a list left open above; the one holding, else after, else before"
  (let ([f (scheme-buffer "f.ss" "; head\n(define (a)\n  (b\n(define (c) 1)\n  (d))\n'(e)\n; tail\n")])
    (check-equal? '("(define (a)\n  (b" "(define (a)\n  (b" "(define (a)\n  (b" "(define (c) 1)" "(define (c) 1)" "(define (c) 1)" "(define (c) 1)")
                  (map (lambda (at) (form f (after f at))) '("; he" "(defi" "(b" "(c) 1" "(d))" "'(e" "; ta")))))

(test "closed, the first form still ends before the column-0 one inside it, and the text after that inner form belongs to no form"
  (let ([g (scheme-buffer "g.ss" "; head\n(define (a)\n  (b\n(define (c) 1)\n  (d)))\n'(e)\n; tail\n")])
    (check-equal? '("(define (a)\n  (b" "(define (c) 1)" "'(e)" "'(e)" "'(e)") (map (lambda (at) (form g (after g at))) '("(defi" "(c) 1" "(d))" "'(e" "; ta")))
    (check-equal? #f (form (scheme-buffer "empty.ss" "; nothing\n") 3))))
