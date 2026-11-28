(import (tuna) (test) (languages) (modes) (buffers) (document) (hooks) (tables) (syntax) (buffers-test) (syntax-test))

(tables:define-table keymap "Keys.")
(hooks:define-hook hook "Setup.")
(modes:define-major-mode shell (keymap keymap) (hook hook))
(modes:define-major-mode json (keymap keymap) (hook hook))
(modes:define-major-mode css (keymap keymap) (hook hook))
(modes:define-major-mode pyish (keymap keymap) (hook hook))
(modes:define-major-mode plain (keymap keymap) (hook hook))
(modes:define-major-mode counted (keymap keymap) (hook hook))

(languages:define-language "shellish" (mode shell)
  (line-comments ("#" word-start))
  (strings ("\"" "\"" (escape #\\)) ("'" "'"))
  (brackets ("(" ")") ("[" "]") ("{" "}"))
  (symbol-characters "_-."))
(languages:define-language "jsonish" (mode json)
  (strings ("\"" "\"" (escape #\\) line-bound))
  (brackets ("{" "}") ("[" "]")))
(languages:define-language "cssish" (mode css)
  (block-comments ("/*" "*/"))
  (strings ("\"" "\"" (escape #\\) line-bound))
  (brackets ("(" ")") ("{" "}")))
(languages:define-language "pyish" (mode pyish)
  (line-comments ("#"))
  (strings ("\"\"\"" "\"\"\"" (escape #\\)) ("\"" "\"" (escape #\\) line-bound))
  (brackets ("(" ")")))
(languages:define-language "plain" (mode plain) (file-names "plain"))

(define (lexemes-of mode text)
  (map (lambda (l) (list (syntax:lexeme-class l) (document:text (document:from-datum text) (syntax:lexeme-start l) (syntax:lexeme-end l))
                         (syntax:lexeme-depth l) (syntax:lexeme-open-ended? l) (syntax:lexeme-mismatched? l)))
       (vector->list ((syntax:lexer mode) (document:from-datum text)))))

(define (buffer-of mode text)
  (let ([b (buffers:make (buffers:free-name "lexed") text)])
    (modes:set-major-mode mode b)
    b))

(test "a mode whose language declares comments, strings or brackets has a lexer made from them, the same procedure while they are unchanged"
  (let ([lexer (syntax:lexer shell)])
    (check (procedure? lexer))
    (check (eq? lexer (syntax:lexer shell)))
    (let ([configuration (make-owner '(configuration))])
      (call-as-owner configuration (lambda () (tables:set! languages:symbol-characters "shellish" "_")))
      (check (not (eq? lexer (syntax:lexer shell))))
      (let ([changed (syntax:lexer shell)])
        (check (eq? changed (syntax:lexer shell)))
        (unload-owner! configuration)
        (check (not (eq? changed (syntax:lexer shell)))))))
  (check-equal? #f (syntax:lexer plain))
  (check-equal? #f (syntax:lexer modes:fundamental)))

(test "a mode's own entry in syntax:lexers wins over its language's lexer"
  (let ([own (lambda (doc) '#())])
    (tables:set! syntax:lexers json own)
    (check (eq? own (syntax:lexer json)))
    (tables:remove! syntax:lexers json)
    (check (not (eq? own (syntax:lexer json))))))

(test "a string holds a comment start, and a comment after it runs to the line's end, open-ended"
  (check-equal? '((atom "echo" 0 #f #f) (string "\"a # b\"" 0 #f #f) (comment "# c" 0 #t #f) (atom "x" 0 #f #f))
                (lexemes-of shell "echo \"a # b\" # c\nx")))

(test "a start marked word-start counts only after a character that is not a letter, digit or symbol character, or at a line's start"
  (check-equal? '((atom "echo" 0 #f #f) (atom "a#b" 0 #f #f) (atom "x-#y" 0 #f #f) (comment "#z" 0 #t #f))
                (lexemes-of shell "echo a#b x-#y\n#z")))

(test "an escape makes the next character part of the string; brackets nest and give depth"
  (check-equal? '((open "{" 1 #f #f) (string "\"a\"" 1 #f #f) (atom ":" 1 #f #f) (string "\"x\\\"y\"" 1 #f #f) (close "}" 1 #f #f))
                (lexemes-of json "{\"a\": \"x\\\"y\"}")))

(test "an unterminated block comment is open-ended to the end of the text; a line-bound string to its line's end"
  (check-equal? '((atom "a" 0 #f #f) (open "{" 1 #f #f) (atom "color:" 1 #f #f) (atom "red" 1 #f #f) (close "}" 1 #f #f)
                  (comment "/* c\nd" 0 #t #f))
                (lexemes-of css "a { color: red } /* c\nd"))
  (check-equal? '((string "\"ab" 0 #t #f) (atom "c" 0 #f #f)) (lexemes-of json "\"ab\nc")))

(test "a closer of another shape than its opener is mismatched; one with no opener has depth 0"
  (check-equal? '((open "(" 1 #f #f) (atom "a" 1 #f #f) (close "]" 1 #f #t) (close "}" 0 #f #f))
                (lexemes-of shell "(a] }")))

(test "of two starts at one place the longer wins, and a start inside a string is plain text"
  (check-equal? '((string "\"\"\"a \" # b\n\"\"\"" 0 #f #f) (comment "# c" 0 #t #f))
                (lexemes-of pyish "\"\"\"a \" # b\n\"\"\" # c")))

(test "the questions answer from the language's lexemes: openings, sexps, strings and matches in a JSON buffer"
  (let* ([b (buffer-of json "{\"a\": [1, {\"b\": 2}], \"c\": 3}")] [at (lambda (s) (syntax-test:after b s))])
    (check-equal? '("{" "[" "{") (map (lambda (l) (syntax-test:between b (syntax:lexeme-start l) (syntax:lexeme-end l)))
                                      (syntax:openings b (at "\"b\""))))
    (check-equal? (syntax-test:after b "{\"b\": 2}") (syntax:sexp-after b (syntax-test:before b "{\"b\"")))
    (check-equal? (syntax-test:before b "[1") (syntax:sexp-before b (syntax-test:after b "2}]")))
    (check (syntax:string-or-comment-at b (at "\"c")))
    (let ([open (syntax:lexeme-starting-at b (syntax-test:before b "["))])
      (check-equal? (syntax-test:before b "], ") (syntax:lexeme-start (syntax:match b open))))))

(define (all-lexemes b)
  (map syntax-test:lexeme->list (syntax:lexemes b 0 (document:length (buffers:document b)))))

(define (whole-lex b)
  (map syntax-test:lexeme->list (vector->list ((syntax:lexer (modes:major-mode b)) (buffers:document b)))))

(define read-from '())

(define counted-lexer
  (let ([base (syntax:lexer pyish)])
    (lambda (doc) (base doc))))

(tables:set! syntax:lexers counted counted-lexer)
(tables:set! syntax:resumers counted-lexer
  (let ([resume (tables:ref syntax:resumers (syntax:lexer pyish) #f)])
    (lambda (doc start state end)
      (set! read-from (cons (cons (document:line doc start) (document:line doc end)) read-from))
      (resume doc start state end))))

(define (reads thunk)
  (set! read-from '())
  (thunk)
  (reverse read-from))

(define (numbered-lines n)
  (call-with-string-output-port
    (lambda (p) (do ([i 1 (+ i 1)]) ((> i n)) (fprintf p "x~a = (~a) # line ~a\n" i i i)))))

(test "a lexer with a resumer is asked from the last line whose state the plugin holds: after an edit on line 5 of 30,000, a question on line 20,000 lexes from line 5, and one on line 4 lexes nothing more"
  (let* ([b (buffer-of counted (numbered-lines 30000))] [line-start (lambda (line) (document:line-start (buffers:document b) line))])
    (syntax:lexeme-at b (line-start 25000))
    (buffers:replace! b (line-start 5) (line-start 5) "y")
    (check-equal? '((5 . 20000)) (reads (lambda () (syntax:lexeme-at b (line-start 20000)))))
    (check (for-all (lambda (read) (>= (car read) 20000))
                    (reads (lambda () (check (syntax:lexeme-at b (fx+ (line-start 4) 1)))))))
    (check-equal? (whole-lex b) (all-lexemes b))))

(test "the lexers made from a language have resumers, the plugin's own entries"
  (check (procedure? (tables:ref syntax:resumers (syntax:lexer pyish) #f)))
  (check-equal? '(syntax) (owner-name (tables:owner syntax:resumers (syntax:lexer pyish)))))

(test "an edit inside a string that spans lines lexes again from its line, with the string's state, so the string is whole"
  (let* ([b (buffer-of pyish "a = 1\ns = \"\"\"one\ntwo\nthree\"\"\"\nb = (2)\n")] [doc (lambda () (buffers:document b))])
    (check-equal? (whole-lex b) (all-lexemes b))
    (buffers:replace! b (syntax-test:after b "tw") (syntax-test:after b "tw") "# (")
    (check-equal? 'string (syntax:lexeme-class (syntax:lexeme-at b (syntax-test:after b "thr"))))
    (check-equal? (whole-lex b) (all-lexemes b))
    (buffers:replace! b (syntax-test:before b "\"\"\"one") (syntax-test:after b "\"\"\"one") "one")
    (check-equal? 'atom (syntax:lexeme-class (syntax:lexeme-at b (syntax-test:after b "on"))))
    (check-equal? (whole-lex b) (all-lexemes b))))

(define (random-edits! mode pieces)
  (let ([b (buffer-of mode "")])
    (do ([i 0 (+ i 1)]) ((= i 400))
      (let* ([doc (buffers:document b)] [last (- (document:length doc) 1)] [at (+ 1 (random last))])
        (if (and (> last 1) (= (random 3) 0))
            (let ([end (min last (+ at 1 (random 3)))])
              (when (< at end) (buffers:replace! b at end "")))
            (buffers:replace! b at at (list-ref pieces (random (length pieces)))))
        (syntax:lexeme-at b (+ 1 (random (- (document:length (buffers:document b)) 1))))
        (unless (equal? (whole-lex b) (all-lexemes b))
          (errorf 'random-edits! "lexemes differ after edit ~a of ~s" i (document:text (buffers:document b))))))))

(test "any run of edits and questions leaves the plugin's lexemes those of lexing the whole text"
  (random-edits! pyish '("\"" "\"\"\"" "#" "\n" "(" ")" "x" " " "\\"))
  (random-edits! css '("/*" "*/" "\"" "\n" "{" "}" "x" " " "\\")))

(test "a language's entry of the wrong shape is reported when the lexer is made, by the reader of its table, naming the language"
  (let ([configuration (make-owner '(configuration))])
    (call-as-owner configuration (lambda () (tables:set! languages:strings "jsonish" '("\""))))
    (check-raises (buffers-test:raised-with? 'languages:strings-of "the entry is not a list of delimiters"
                    (list "jsonish" '("\"")))
                  (syntax:lexer json))
    (unload-owner! configuration)
    (check (procedure? (syntax:lexer json)))))
