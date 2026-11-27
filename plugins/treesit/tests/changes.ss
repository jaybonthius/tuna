(import (tuna) (test) (tables) (options) (treesit) (treesit-test) (treesit-test grammar) (treesit-test session))

(define python (tables:ref treesit:grammars "python" #f))
(define grammar (treesit:grammar-file python))
(treesit-test/grammar:build-python! (treesit:grammar-commit python) grammar)

(define excluded (options:default treesit:excluded-captures))

(define (open text) (treesit-test/session:open grammar text (treesit-test/session:shipped) excluded))

(define settle! treesit-test/session:settle!)
(define replace! treesit-test/session:replace!)
(define runs treesit-test/session:runs)

(test "after a letter typed at the end of a name, the answers hold the whole name"
  (let ([s (treesit-test/session:open grammar "def foo():\n    return bar\n" (treesit-test/session:shipped) '())])
    (check-equal? '((0 26)) (settle! s))
    (replace! s 7 7 "x")
    (check-equal? '((6 9) (4 6)) (settle! s))
    (check-equal? '(("def" keyword.function) ("foox" function) ("()" punctuation.bracket)) (runs s 0 10))))

(test "editing one capture of a match colours its others again, though their text and syntax did not change"
  (let ([s (treesit-test/session:open grammar "T = TypeVar(\"T\")\n"
             (list (treesit-test/session:query!
                     "((assignment left: (identifier) @type right: (call function: (identifier) @_f)) (#eq? @_f \"TypeVar\"))"))
             '())])
    (check-equal? '((0 17)) (settle! s))
    (check-equal? '(("T" type)) (runs s))
    (replace! s 10 11 "z")
    (check-equal? '((9 12) (0 9)) (settle! s))
    (check-equal? '() (runs s))
    (replace! s 10 11 "r")
    (check-equal? '((9 12) (0 9)) (settle! s))
    (check-equal? '(("T" type)) (runs s))))

(test "\"\"\" typed on its own line above a def keeps the colours after it; typed again further down, the text between is a string"
  (let ([s (open "import os\n\n\ndef f(a):\n    return a + 1\n\n\nx = 2\n")])
    (check-equal? '((0 47)) (settle! s))
    (let ([before (runs s 12 47)])
      (check-equal? '(("def" keyword.function) ("f" function) ("a" variable.parameter) ("return" keyword.return) ("1" number)
                      ("x" variable.definition) ("2" number))
                    before)
      (replace! s 10 10 "\"\"\"\n")
      (check-equal? '((9 15)) (settle! s))
      (check-equal? before (runs s 16 51))
      (check-equal? #f (treesit-test/session:fresh-difference s)))
    (replace! s 45 45 "\"\"\"\n")
    (check-equal? "x = 2\n" (substring (treesit-test/session:text s) 49 55))
    (check-equal? '((10 50)) (settle! s))
    (check-equal? '(("import" keyword.import) ("\"\"\"\n\n\ndef f(a):\n    return a + 1\n\n\n\"\"\"" string)
                    ("x" variable.definition) ("2" number))
                  (runs s))
    (check-equal? #f (treesit-test/session:fresh-difference s))))

(test "any edits, in any order, leave the faces a highlight from nothing gives"
  (let ([s (open (treesit-test:sample "sample"))]
        [pieces '("(" ")" "\"\"\"" "'" "#" "\n" "x" " " ":" "[" "f\"{" "}" "\"\"\"\n" "    ")])
    (define (random-edit!)
      (let* ([n (string-length (treesit-test/session:text s))] [start (random (+ n 1))])
        (if (and (> n 0) (= 0 (random 3)))
            (replace! s start (min n (+ start 1 (random 8))) "")
            (replace! s start start (list-ref pieces (random (length pieces)))))))
    (random-seed 20261120)
    (check-equal? '((0 3122)) (settle! s))
    (check-equal? '()
      (let loop ([k 0] [failures '()])
        (if (= k 300)
            (reverse failures)
            (begin
              (random-edit!)
              (when (= 0 (random 2)) (random-edit!))
              (settle! s)
              (loop (+ k 1)
                    (let ([d (treesit-test/session:fresh-difference s)])
                      (if d (cons (cons k d) failures) failures)))))))))
