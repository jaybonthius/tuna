(import (tuna) (test) (tables) (hooks) (modes) (syntax) (buffers) (search) (search-test))

(define b (search-test:text-buffer "w" "user_id foo$x a-b\n"))

(define (rx text) (search-test:all-in b (search:make-query text search:regexp)))

(test "a regexp's \\w, \\W, \\b and \\B follow the buffer's word characters: letters, digits, and $ and % in fundamental, where _ is no word character"
  (check-equal? '((1 5 "user") (6 8 "id") (9 14 "foo$x") (15 16 "a") (17 18 "b")) (rx "\\w+"))
  (check-equal? '((1 5 "user")) (rx "\\buser\\b"))
  (check-equal? '() (rx "\\bfoo\\b"))
  (check-equal? '((10 11 "o") (11 12 "o")) (rx "o\\B"))
  (check-equal? '((5 6 "_") (8 9 " ") (14 15 " ") (16 17 "-") (18 19 "\n")) (rx "\\W")))

(test "in a class \\w adds the word characters and \\W the others, negated or not"
  (check-equal? '((1 8 "user_id") (9 14 "foo$x") (15 16 "a") (17 18 "b")) (rx "[\\w_]+"))
  (check-equal? '((5 6 "_") (16 17 "-") (18 19 "\n")) (rx "[^\\w ]"))
  (check-equal? '((5 6 "_") (8 9 " ") (14 15 " ") (16 17 "-") (18 19 "\n")) (rx "[-\\W]"))
  (check-equal? '((1 5 "user") (6 8 "id") (9 14 "foo$x") (15 16 "a") (17 18 "b")) (rx "[^-\\W]+"))
  (check-equal? (rx "\\W") (rx "[\\W]"))
  (check-equal? (rx "\\w") (rx "[^\\W]")))

(test "an escaped backslash, \\Q...\\E and a comment leave \\w alone"
  (let* ([lit (search-test:text-buffer "lit" "a\\w \\Q\\w\\E\n")] [all (lambda (text) (search-test:all-in lit (search:make-query text search:regexp)))])
    (check-equal? '((2 4 "\\w") (7 9 "\\w")) (all "\\\\w"))
    (check-equal? '((2 4 "\\w") (7 9 "\\w")) (all "\\Q\\w\\E"))
    (check-equal? '((1 2 "a")) (all "a(?#\\w)"))))

(test "[[:word:]] keeps PCRE2's meaning, with _"
  (check-equal? '((1 8 "user_id") (9 12 "foo") (13 14 "x") (15 16 "a") (17 18 "b")) (rx "[[:word:]]+")))

(test "a hyphen next to \\w in a class is refused, as PCRE2 refuses [\\w-z]"
  (check-equal? "invalid range in character class"
                (guard (c [(search:pattern-error? c) (condition-message c)]) (rx "[\\w-z]"))))

(tables:define-table odd-keymap)
(hooks:define-hook odd-hook)
(modes:define-major-mode odd-mode (keymap odd-keymap) (hook odd-hook))

(test "a mode's own word characters each match only themselves, metacharacters included"
  (tables:set! syntax:word-characters odd-mode "sd]-\\")
  (let ([o (search-test:text-buffer "odd" "a]b-c\\d e+f\n")])
    (modes:set-major-mode odd-mode o)
    (check-equal? '((1 8 "a]b-c\\d") (9 10 "e") (11 12 "f")) (search-test:all-in o (search:make-query "\\w+" search:regexp)))
    (check-equal? '() (search-test:all-in o (search:make-query "\\bb-c\\b" search:regexp)))
    (let* ([seen #f]
           [words (search:make-style "Words" (lambda (text partial? classes)
                                               (set! seen (search:classes-word classes))
                                               (string-append seen "+")))])
      (check-equal? '((1 8 "a]b-c\\d") (9 10 "e") (11 12 "f")) (search-test:all-in o (search:make-query "" words)))
      (check-equal? "[\\p{Alphabetic}\\x{73}\\x{64}\\x{5D}\\x{2D}\\x{5C}\\p{N}]" seen))))

(test "advice on syntax:buffer-word-characters reaches regexps and the word style"
  (let ([with-underscore (lambda (chars buffer) (if (eq? buffer b) (string-append (chars buffer) "_") (chars buffer)))])
    (advice-add! syntax:buffer-word-characters with-underscore)
    (check-equal? '((1 8 "user_id") (9 14 "foo$x") (15 16 "a") (17 18 "b")) (rx "\\w+"))
    (check-equal? '() (search-test:all-in b (search:make-query "user" search:word)))
    (advice-remove! syntax:buffer-word-characters with-underscore)
    (check-equal? '((1 5 "user")) (search-test:all-in b (search:make-query "user" search:word)))))

(test "the class holds what syntax counts as a word character: Alphabetic, so a vowel sign, and numbers of every kind"
  (let ([k (search-test:text-buffer "k" "किताब Ⅻ² x\n")])
    (check-equal? '((1 6 "किताब") (7 9 "Ⅻ²") (10 11 "x")) (search-test:all-in k (search:make-query "\\w+" search:regexp)))
    (check-equal? '() (search-test:all-in k (search:make-query "ताब" search:word)))))

(test "over every character, \\w agrees with what syntax counts as a word character, but for those only Chez's newer Unicode counts"
  (let* ([chars (filter (lambda (n) (not (or (<= #xD800 n #xDFFF) (= n 10)))) (iota #x30000))]
         [every (search-test:text-buffer "every" (list->string (map integer->char chars)))]
         [word? (lambda (c) (or (char-alphabetic? c) (char-numeric? c) (memv c '(#\$ #\%))))]
         [by-chez (filter (lambda (n) (word? (integer->char n))) chars)]
         [by-pcre2 (map (lambda (m) (char->integer (string-ref (buffers:text-between (buffers:document every) (search:match-start m) (search:match-end m)) 0)))
                        (search:scan-matches (search-test:scanned every (search:make-query "\\w" search:regexp)) 0 (search-test:end-of every)))]
         [missing (lambda (from in)
                    (let ([t (make-eqv-hashtable)])
                      (for-each (lambda (n) (hashtable-set! t n #t)) in)
                      (filter (lambda (n) (not (hashtable-ref t n #f))) from)))])
    (check-equal? '(135679 0 5665) (list (length by-chez) (length (missing by-pcre2 by-chez)) (length (missing by-chez by-pcre2))))))
