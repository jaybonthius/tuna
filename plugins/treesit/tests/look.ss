(import (tuna) (test) (tables) (options) (languages) (treesit) (python) (treesit-test) (treesit-test grammar) (treesit-test session))

(define python python:python)
(define grammar (treesit:grammar-file python))
(treesit-test/grammar:build-python! (languages:grammar-commit python) grammar)

(define (string-prefix? prefix s)
  (let ([n (string-length prefix)]) (and (<= n (string-length s)) (string=? prefix (substring s 0 n)))))

(define (string-suffix? suffix s)
  (let ([n (string-length suffix)] [m (string-length s)]) (and (<= n m) (string=? suffix (substring s (- m n) m)))))

;; The letters Emacs's categories are recorded in, one a character: K
;; keyword, D definition, U variable use, F function name, C call, T
;; type, B builtin, N constant, 9 number, S string, O docstring, E
;; escape, M comment, P property, Y module, and a dot for none or
;; punctuation.
(define (category face)
  (let ([name (cond [(not face) #f] [(pair? face) (symbol->string (car face))] [else (symbol->string face)])])
    (cond
      [(not name) #\.]
      [(member name '("variable.definition" "variable.parameter")) #\D]
      [(string=? name "variable") #\U]
      [(string=? name "variable.member") #\P]
      [(member name '("type.builtin" "constructor")) #\T]
      [(string=? name "string.documentation") #\O]
      [(string=? name "string.escape") #\E]
      [(string-suffix? ".builtin" name) #\B]
      [(string-prefix? "keyword" name) #\K]
      [(member name '("function.call" "function.method.call")) #\C]
      [(string-prefix? "function" name) #\F]
      [(or (string-prefix? "type" name) (string-prefix? "attribute" name)) #\T]
      [(member name '("constant" "boolean" "character")) #\N]
      [(string-prefix? "number" name) #\9]
      [(string-prefix? "string" name) #\S]
      [(string-prefix? "comment" name) #\M]
      [(string-prefix? "module" name) #\Y]
      [(or (string-prefix? "punctuation" name) (string-prefix? "operator" name) (string-prefix? "character.special" name)) #\.]
      [else #\?])))

(define (compared name level)
  (let* ([text (treesit-test:sample name)]
         [emacs (treesit-test:emacs-categories name level)]
         [s (treesit-test/session:highlighted grammar text (treesit-test/session:shipped)
              (if (= level 3) (options:default treesit:excluded-captures) '()))]
         [v (list->vector (treesit-test/session:faces s))]
         [kinds '()])
    (let loop ([i 0] [line 1])
      (when (< i (string-length text))
        (let ([c (string-ref text i)])
          (cond
            [(char=? c #\newline) (loop (+ i 1) (+ line 1))]
            [(memv c '(#\space #\tab)) (loop (+ i 1) line)]
            [else
             (let ([e (string-ref emacs i)] [t (category (vector-ref v i))])
               (if (char=? e t)
                   (loop (+ i 1) line)
                   (let run ([k i])
                     (if (and (< k (string-length text)) (not (char=? (string-ref text k) #\newline))
                              (char=? (string-ref emacs k) e) (char=? (category (vector-ref v k)) t))
                         (run (+ k 1))
                         (let* ([key (string e #\- #\> t)] [old (assoc key kinds)] [found (list line (substring text i k))])
                           (set! kinds
                             (if old
                                 (cons (list key (+ (cadr old) (- k i)) (append (caddr old) (list found))) (remove old kinds))
                                 (cons (list key (- k i) (list found)) kinds)))
                           (loop k line))))))]))))
    (list-sort (lambda (a b) (string<? (car a) (car b))) kinds)))

(test "the default look is Emacs 30.2's at its default font lock level, 3, and with nothing excluded its level 4, but for differences Tuna makes on purpose"
  ;; {{ and }} in an f-string are escapes of a brace, as nvim-treesitter
  ;; captures them; Python 3.12's type X = ... and 3.11's except* are
  ;; keywords, newer than Emacs's mode; type(mock)._check = checker
  ;; parses as a type alias; with nothing excluded, a name assigned in a
  ;; class body through a subscript or attribute is a member, which
  ;; nvim-treesitter's rule reaches and Emacs's does not.
  (check-equal? '((".->K" 8 ((95 "type") (96 "type"))) ("S->E" 4 ((23 "{{") (23 "}}")))) (compared "sample" 3))
  (check-equal? '((".->K" 8 ((95 "type") (96 "type"))) ("S->E" 4 ((23 "{{") (23 "}}"))) ("U->P" 9 ((74 "_registry"))))
                (compared "sample" 4))
  (check-equal? '(("S->E" 4 ((37 "{{") (37 "}}")))) (compared "definitions" 3))
  (check-equal? '(("S->E" 4 ((37 "{{") (37 "}}")))) (compared "definitions" 4))
  (check-equal? '() (compared "type-variables" 3))
  (check-equal? '() (compared "type-variables" 4))
  (check-equal? '((".->K" 10 ((59 "except") (73 "type")))) (compared "newer-syntax" 3))
  (check-equal? '((".->K" 10 ((59 "except") (73 "type")))) (compared "newer-syntax" 4)))
