(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (buffers) (document) (views) (layout) (files)
        (lsp) (servers))

(options:set! lsp:send-changes-delay 0.05)

(define (edit line from to text)
  `(("range" ("start" ("line" . ,line) ("character" . ,from)) ("end" ("line" . ,line) ("character" . ,to))) ("newText" . ,text)))

(define (whole-edit text)
  `(("range" ("start" ("line" . 0) ("character" . 0)) ("end" ("line" . 100000) ("character" . 0))) ("newText" . ,text)))

(define (format-answer! . edits)
  (servers:configure! "shaper"
    '(capabilities ("textDocumentSync" . 2) ("documentFormattingProvider" . #t) ("documentRangeFormattingProvider" . #t)
                   ("documentOnTypeFormattingProvider" ("firstTriggerCharacter" . "\n")))
    `(responses ("textDocument/formatting" . ,(list->vector edits))
                ("textDocument/rangeFormatting" . #(,(edit 1 0 0 "  "))))
    '(name . "shaper")))

(lsp:define-server shaper (servers:fake-command "shaper"))

(format-answer!)

(tables:set! lsp:language-servers "fakelang" (list shaper))

(hooks:add! servers:fake-mode-hook lsp:ensure)

(define path (string-append servers:project "/e.fk"))

(servers:write-file! path "\n")

(define c (servers:visit! path))

(servers:wait-for "shaper" "textDocument/didOpen")

(define (around)
  (let ([doc (buffers:document c)] [p (views:point (servers:view))])
    (list (document:text doc 0 p) (document:text doc p (document:length doc)))))

(define (fresh! content before)
  (buffers:replace! c 1 (- (document:length (buffers:document c)) 1) content)
  (views:set-point! (servers:view) (+ 1 (string-length before))))

(define (format!) (views:call-with-view (servers:view) (lambda () (lsp:format-buffer c))))

(test "edits at one start apply as the protocol says: inserts there in the list's order, then the replacement; an insert listed after the replacement is kept before it"
  (format-answer! (edit 0 0 0 "a") (edit 0 0 0 "b") (edit 0 0 1 "Z"))
  (fresh! "xyz\n" "xyz")
  (format!)
  (check-equal? '("abZyz" "\n") (around))
  (format-answer! (edit 0 0 1 "Z") (edit 0 0 0 "a"))
  (fresh! "xyz\n" "xyz")
  (format!)
  (check-equal? '("aZyz" "\n") (around)))

(test "an edit that replaces the whole text is one change to the buffer and to the server, and point in text it keeps stays with that text"
  (format-answer! (whole-edit "(let ([a 1])\n  (+ a b))\n"))
  (let ([before (length (servers:of-method "shaper" "textDocument/didChange"))])
    (fresh! "(let ([a 1]) (+ a b))\n" "(let ([a 1]) (+ a ")
    (servers:wait-for "shaper" "textDocument/didChange" (+ before 1)))
  (let ([version (buffers:version c)] [changes (length (servers:of-method "shaper" "textDocument/didChange"))])
    (format!)
    (servers:wait-for "shaper" "textDocument/didChange" (+ changes 1))
    (check-equal? '(("(let ([a 1])\n  (+ a " "b))\n") 1 1)
                  (list (around) (- (buffers:version c) version)
                        (vector-length (servers:ref (servers:last-of "shaper" "textDocument/didChange") "params" "contentChanges"))))))

(test "the server's edits are not typing: one that leaves a single line break asks for no on-type formatting"
  (options:set! lsp:on-type-formatting? #t)
  (format-answer! (whole-edit "x = 1\ny = 2\n"))
  (fresh! "x = 1; y = 2\n" "")
  (format!)
  (check-equal? '("x = 1\ny = 2\n" 0) (list (servers:text c) (length (servers:of-method "shaper" "textDocument/onTypeFormatting"))))
  (options:unset! lsp:on-type-formatting?))

(test "formatting moves point in a line's indentation as typing does; whitespace elsewhere is only text the difference keeps or not"
  (format-answer! (whole-edit "(let ([a 1])\n  (+ a b))\n"))
  (fresh! "(let ([a 1])\n (+ a   b))\n" "(let ([a 1])\n")
  (format!)
  (check-equal? '("(let ([a 1])\n  " "(+ a b))\n") (around))
  (fresh! "(let ([a 1])\n (+ a   b))\n" "(let ([a 1])\n (+ a")
  (format!)
  (check-equal? '("(let ([a 1])\n  (+ a" " b))\n") (around)))

(test "a point the edits carry out of a line's indentation, as when they join its line to the one before, keeps its place in the text"
  (format-answer! (whole-edit "  x y\n"))
  (fresh! "  x\ny\n" "  x\n")
  (format!)
  (check-equal? '("  x " "y\n") (around)))

(test "a region from a line's start keeps its mark there when the server indents the line, as a mark is an anchor"
  (fresh! "(a\nb)\n" "(a\nb")
  (views:set-mark! (servers:view) 4)
  (views:call-with-view (servers:view) lsp:format)
  (check-equal? '(4 ("(a\n  b" ")\n")) (list (views:mark (servers:view)) (around))))

(define (numbered n f) (apply string-append (map f (iota n))))

(test "past the search's cap of differences, the split it falls back on still gives the server's text in one change, and point stays with its text"
  (let ([reindented (numbered 2000 (lambda (i) (format "    (define (f~a x) (+ x ~a))\n" i i)))])
    (format-answer! (whole-edit reindented))
    (fresh! (numbered 2000 (lambda (i) (format "  (define (f~a x) (+ x ~a))\n" i i)))
            (string-append (numbered 1000 (lambda (i) (format "  (define (f~a x) (+ x ~a))\n" i i))) "  (define (f1000 x) "))
    (let ([version (buffers:version c)])
      (format!)
      (check-equal? (list #t 1 (+ 1 (string-length (numbered 1000 (lambda (i) (format "    (define (f~a x) (+ x ~a))\n" i i))))
                                  (string-length "    (define (f1000 x) ")))
                    (list (equal? (servers:text c) reindented) (- (buffers:version c) version) (views:point (servers:view)))))))

(test "whole-text edits between random texts give the server's text"
  (random-seed 7)
  (let ([random-text (lambda () (list->string (map (lambda (i) (string-ref "ab \n" (random 4))) (iota (random 30)))))])
    (check-equal? '()
                  (let loop ([n 0] [wrong '()])
                    (if (= n 40)
                        wrong
                        (let ([old (random-text)] [new (random-text)])
                          (format-answer! (whole-edit new))
                          (buffers:replace! c 1 (- (document:length (buffers:document c)) 1) old)
                          (format!)
                          (loop (+ n 1) (if (equal? (servers:text c) new) wrong (cons (list old new (servers:text c)) wrong)))))))))

(test "an edit whose differences cost too much to find replaces its range whole, and a point or mark inside it keeps its line and column, or the line's end when the new line is shorter"
  (random-seed 5)
  (let* ([random-lines (lambda (n) (apply string-append (map (lambda (i) (string-append (list->string (map (lambda (j) (string-ref "ab " (random 3))) (iota (random 13)))) "\n")) (iota n))))]
         [old (string-append "keep\n" (random-lines 60000))]
         [new (string-append "keep\n" (random-lines 60000))]
         [line-start (lambda (s line) (let loop ([i 0] [l 0]) (if (= l line) i (loop (+ i 1) (if (char=? (string-ref s i) #\newline) (+ l 1) l)))))]
         [line-length (lambda (s line) (let ([i (line-start s line)]) (let loop ([j i]) (if (char=? (string-ref s j) #\newline) (- j i) (loop (+ j 1))))))]
         [line-where (lambda (ok?) (let loop ([l 1000]) (if (ok? l) l (loop (+ l 1)))))]
         [point-line (line-where (lambda (l) (and (>= (line-length old l) 10) (>= (line-length new l) 10))))]
         [mark-line (line-where (lambda (l) (and (>= (line-length old l) 12) (< (line-length new l) 6))))])
    (format-answer! `(("range" ("start" ("line" . 1) ("character" . 0)) ("end" ("line" . 60001) ("character" . 0)))
                      ("newText" . ,(substring new 5 (string-length new)))))
    (buffers:replace! c 1 (- (document:length (buffers:document c)) 1) old)
    (views:set-mark! (servers:view) (+ 1 (line-start old mark-line) 12))
    (views:set-point! (servers:view) (+ 1 (line-start old point-line) 9))
    (format!)
    (check (equal? (servers:text c) new))
    (check-equal? '(9 #t)
                  (list (- (views:point (servers:view)) 1 (line-start new point-line))
                        (= (views:mark (servers:view)) (+ 1 (line-start new mark-line) (line-length new mark-line)))))))
