(import (tuna) (test) (test-runner) (modes) (buffers) (tables) (syntax) (syntax-highlighting) (chez-scheme) (syntax-test)
        (chez-scheme-test scheme-buffers))

(define b (buffers:make "lexed.ss" "(car '(a b)) ; c\n"))

(modes:set-major-mode chez-scheme:mode b)

(define (two-values thunk) (call-with-values thunk list))

(test "the page's lexer and lexeme examples"
  (check (eq? chez-scheme:lexer (syntax:lexer chez-scheme:mode)))
  (check-equal? '(open 1 2 1) (syntax-test:lexeme->list (syntax:make-lexeme (syntax:class open) 1 2 1 (syntax:lexeme-marks)))))

(test "the page's question examples"
  (check-equal? '((prefix 6 7 1) (open 7 8 2) (atom 8 9 2)) (map syntax-test:lexeme->list (syntax:lexemes b 6 9)))
  (check-equal? '(comment 14 17 0) (syntax-test:lexeme->list (syntax:lexeme-at b 15)))
  (check-equal? '(comment 14 17 0) (syntax-test:lexeme->list (syntax:lexeme-at b 17)))
  (check-equal? #f (syntax:lexeme-at b 6))
  (check-equal? '((open 1 2 1) (open 7 8 2)) (map syntax-test:lexeme->list (syntax:openings b 9)))
  (check-equal? '(6 1) (list (syntax:sexp-before b 12) (syntax:sexp-before b 13)))
  (let ([e (buffers:make "commented.ss" ";; (greet:text \"x\")\n")])
    (modes:set-major-mode chez-scheme:mode e)
    (check-equal? 4 (syntax:sexp-before e 20)))
  (check-equal? 12 (syntax:sexp-after b 5))
  (check-equal? '(1 13) (two-values (lambda () (syntax:top-level-form b 9))))
  (check-equal? '(1 13) (two-values (lambda () (syntax:top-level-form b 15)))))

(test "the page's word and symbol examples"
  (check-equal? "$%" (syntax:mode-word-characters chez-scheme:mode))
  (check-equal? "!$%&*/:<=>?^_~+-.@" (syntax:mode-symbol-characters chez-scheme:mode))
  (let ([p (buffers:make "plain" "(buffers:insert! b)")])
    (check-equal? '(10 16) (two-values (lambda () (syntax:symbol-bounds p 12))))
    (check-equal? '(2 17) (two-values (lambda () (syntax:symbol-bounds p 12 chez-scheme:mode))))))

(test "the page's bracket layer example"
  (tables:set! syntax:bracket-users 'test (lambda (buffer) #t))
  (syntax-highlighting:update!)
  (test-runner:wait-until
    (lambda () (equal? '((1 2 ((bracket . 1))) (7 8 ((bracket . 2))) (11 12 ((bracket . 2))) (12 13 ((bracket . 1))))
                       (buffers:spans (buffers:layer b syntax:brackets) 1 13))))
  (tables:remove! syntax:bracket-users 'test)
  (syntax-highlighting:update!))
