(import (tuna) (test) (modes) (prog) (buffers) (document) (hooks) (tables) (syntax) (chez-scheme) (buffers-test) (syntax-test)
        (chez-scheme-test scheme-buffers))

(tables:define-table derived-keymap)
(hooks:define-hook derived-hook)
(modes:define-major-mode derived (parent chez-scheme:mode) (keymap derived-keymap) (hook derived-hook))

(define calls 0)

(define (counting-lexer doc) (set! calls (+ calls 1)) (chez-scheme:lexer doc))

(test "a mode derived from one with a lexer uses it unless it has an entry of its own; a mode with none has no lexer"
  (check (eq? chez-scheme:lexer (syntax:lexer derived)))
  (check-equal? '(#f #f) (list (syntax:lexer modes:fundamental) (syntax:lexer prog:mode)))
  (tables:set! syntax:lexers derived counting-lexer)
  (check (eq? counting-lexer (syntax:lexer derived))))

(define (refuses? set symbol)
  (lambda (c)
    (and (syntax-violation? c) (eq? symbol (syntax->datum (syntax-violation-form c)))
         (string=? (format "universe of ~a does not include specified symbol" set) (condition-message c)))))

(test "lexeme classes and marks are checked when their forms expand"
  (check-raises (refuses? "class" 'opne) (load-module! '(syntax-test unknown-class)))
  (check-raises (refuses? "%lexeme-mark" 'mismatch) (load-module! '(syntax-test unknown-mark))))

(test "a lexeme has a class, a start, an end, a depth and marks"
  (let ([l (syntax:make-lexeme (syntax:class string) 3 9 2 (syntax:lexeme-marks open-ended))])
    (check-equal? '(string 3 9 2 #t #f #t #f)
                  (list (syntax:lexeme-class l) (syntax:lexeme-start l) (syntax:lexeme-end l) (syntax:lexeme-depth l)
                        (syntax:lexeme-open-ended? l) (syntax:lexeme-mismatched? l) (syntax:lexeme? l) (syntax:lexeme? 'string)))))

(test "make-lexeme checks its class, its range and its marks; the accessors check their lexeme"
  (check-raises (buffers-test:raised? 'syntax:make-lexeme "not a lexeme class") (syntax:make-lexeme 'word 1 2 0 (syntax:lexeme-marks)))
  (check-raises (buffers-test:raised? 'syntax:make-lexeme "not a lexeme class") (syntax:make-lexeme "open" 1 2 0 (syntax:lexeme-marks)))
  (check-raises (buffers-test:raised? 'syntax:make-lexeme "not a range") (syntax:make-lexeme (syntax:class atom) 2 2 0 (syntax:lexeme-marks)))
  (check-raises (buffers-test:raised? 'syntax:make-lexeme "not a set of lexeme marks") (syntax:make-lexeme (syntax:class atom) 1 2 0 '(open-ended)))
  (check-raises (buffers-test:raised? 'syntax:lexeme-start "not a lexeme") (syntax:lexeme-start 'x)))

(define d (buffers:make "d.ss" "(a (b c) d)\n"))

(modes:set-major-mode derived d)

(test "questions about sexps and top-level forms lex the whole text once per document; an edit makes a new document"
  (set! calls 0)
  (check-equal? '(4 9) (list (syntax:sexp-before d 9) (syntax:sexp-after d 3)))
  (check-equal? 1 calls)
  (buffers:replace! d 1 1 " ")
  (check-equal? '(5 10) (list (syntax:sexp-before d 10) (syntax:sexp-after d 4)))
  (check-equal? 2 calls))

(test "questions about the text near a position lex the top-level forms around it, once per document whatever is asked there"
  (let ([ask (lambda () (list (length (syntax:openings d 6)) (syntax:lexeme-at d 6) (map syntax-test:lexeme->list (syntax:lexemes d 6 7))))])
    (check-equal? '(2 #f ((atom 6 7 2))) (ask))
    (let ([asked calls])
      (check-equal? '(2 #f ((atom 6 7 2))) (ask))
      (check-equal? asked calls))))

(tables:define-table unhighlighted-keymap)
(hooks:define-hook unhighlighted-hook)
(modes:define-major-mode unhighlighted (parent prog:mode) (keymap unhighlighted-keymap) (hook unhighlighted-hook))
(tables:set! syntax:lexers unhighlighted chez-scheme:lexer)

(define (unhighlighted-buffer name text)
  (let ([b (buffers:make name text)])
    (modes:set-major-mode unhighlighted b)
    b))

(test "a document's lexemes are kept only while something else holds the document"
  (let* ([kept (unhighlighted-buffer "kept.ss" "(a b)\n")])
    (check-equal? 1 (syntax:sexp-before kept 6))
    (let ([old (weak-cons (buffers:document kept) '())])
      (buffers:replace! kept 1 1 " ")
      (check-equal? 2 (syntax:sexp-before kept 7))
      (buffers:replace! kept 1 1 " ")
      (check-equal? 3 (syntax:sexp-before kept 8))
      (collect (collect-maximum-generation))
      (check (bwp-object? (car old))))))

(define lexed 0)

(tables:set! syntax:lexers unhighlighted (lambda (doc) (set! lexed (+ lexed (document:length doc))) (chez-scheme:lexer doc)))

(test "the openings deep in 2,000 forms lex about that form's text, not the buffer's"
  (let* ([forms (unhighlighted-buffer "forms.ss" (apply string-append (map (lambda (k) (format "(define (f~a x)\n  (g x\n     ~a))\n" k k)) (iota 2000))))]
         [middle (+ (document:line-start (buffers:document forms) 3002) 5)])
    (set! lexed 0)
    (check-equal? '("(define (" "(g x\n    ")
                  (map (lambda (o) (syntax-test:between forms (syntax:lexeme-start o) (+ (syntax:lexeme-start o) 9))) (syntax:openings forms middle)))
    (check (< lexed 2000))
    (check-equal? 71782 (document:length (buffers:document forms)))))

(test "those forms run from the last line before the position that starts with an opening bracket, as beginning-of-defun finds it"
  (let ([o (unhighlighted-buffer "o.ss" "(define (f x)\n(g x))\n")])
    (check-equal? '(1) (map syntax:lexeme-start (syntax:openings o 15)))
    (check-equal? '(15) (map syntax:lexeme-start (syntax:openings o 16)))))

(test "a whitespace edit between lexemes moves the lexemes read rather than lexing again; any other edit lexes again"
  (let ([w (unhighlighted-buffer "w.ss" "(define (f x)\n  (g x\n    (h x)))\n")])
    (check-equal? '(1 17) (map syntax:lexeme-start (syntax:openings w 26)))
    (let ([read lexed])
      (buffers:replace! w 22 22 "  ")
      (check-equal? '(1 17) (map syntax:lexeme-start (syntax:openings w 28)))
      (check-equal? '((open 28 29 3) (atom 29 30 3)) (map syntax-test:lexeme->list (syntax:lexemes w 28 30)))
      (check-equal? read lexed)
      (buffers:replace! w 29 29 "z")
      (check-equal? '((open 28 29 3) (atom 29 31 3)) (map syntax-test:lexeme->list (syntax:lexemes w 28 31)))
      (check (> lexed read)))))

(test "deleting the only blank between two atoms joins them, so it lexes again"
  (let ([j (unhighlighted-buffer "j.ss" "(define (f)\n  (foo bar))\n")])
    (check-equal? '((atom 16 19 2) (atom 20 23 2)) (map syntax-test:lexeme->list (syntax:lexemes j 16 23)))
    (buffers:replace! j 19 20 "")
    (check-equal? '((atom 16 22 2)) (map syntax-test:lexeme->list (syntax:lexemes j 16 22)))))

(test "indenting the line after an unclosed string makes it stop starting a form, so the string runs on past it"
  (let ([unclosed (unhighlighted-buffer "unclosed.ss" "(define (f)\n  (g \"abc\n(h y)\n(k z)\n")])
    (check-equal? '(string 18 23 2) (syntax-test:lexeme->list (syntax:lexeme-at unclosed 20)))
    (buffers:replace! unclosed 23 23 "  ")
    (check-equal? '(string 18 31 2) (syntax-test:lexeme->list (syntax:lexeme-at unclosed 20)))))

(test "indenting each line of a form whose lines each started a form reads the text about once"
  (let ([body (unhighlighted-buffer "body.ss" (string-append "(let ()\n" (apply string-append (map (lambda (k) (format "(define (f~a x)\n  (g x))\n" k)) (iota 500))) "(f0 1))\n"))])
    (set! lexed 0)
    (let loop ([line 2])
      (when (< line 1002)
        (let ([start (document:line-start (buffers:document body) line)])
          (syntax:openings body start)
          (buffers:replace! body start start "  ")
          (loop (+ line 1)))))
    (check (< lexed (* 3 (document:length (buffers:document body)))))))

(test "questions raise on another thread, past the end of the buffer, and for a mode without a lexer"
  (check-equal? '(syntax:sexp-before "not on the main thread") (buffers-test:on-thread (lambda () (syntax:sexp-before d 3))))
  (check-raises (buffers-test:raised? 'syntax:openings "not a position in the buffer") (syntax:openings d 99))
  (check-raises (buffers-test:raised? 'syntax:lexemes "not a position in the buffer") (syntax:lexemes d 0 99))
  (check-raises (buffers-test:raised? 'syntax:lexeme-at "the mode has no lexer") (syntax:lexeme-at d 1 modes:fundamental)))

(test "a lexer that raises, or returns anything but lexemes in order within the document, makes the question raise, naming the lexer"
  (tables:set! syntax:lexers derived (lambda (doc) (car '())))
  (check-raises (lambda (c) (and (eq? 'syntax:sexp-after (condition-who c))
                                 (let ([m (condition-message c)] [start "the lexer of test-file/syntax/lexemes:derived raised"])
                                   (and (>= (string-length m) (string-length start)) (string=? start (substring m 0 (string-length start)))))))
                (syntax:sexp-after d 1))
  (tables:set! syntax:lexers derived
    (lambda (doc)
      (vector (syntax:make-lexeme (syntax:class atom) 1 4 0 (syntax:lexeme-marks))
              (syntax:make-lexeme (syntax:class atom) 3 5 0 (syntax:lexeme-marks)))))
  (check-raises (buffers-test:raised? 'syntax:sexp-after "the lexer did not return lexemes in order within the document") (syntax:sexp-after d 1))
  (tables:set! syntax:lexers derived (lambda (doc) (list)))
  (check-raises (buffers-test:raised? 'syntax:sexp-after "the lexer did not return lexemes in order within the document") (syntax:sexp-after d 1))
  (tables:remove! syntax:lexers derived))
