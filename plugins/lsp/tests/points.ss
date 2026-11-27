(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (buffers) (document) (views) (layout)
        (layout-split) (editing) (indentation) (files) (lsp) (lsp-test servers))

(options:set! lsp:send-changes-delay 0.05)

(lsp:define-server shaper (lsp-test/servers:fake-command "shaper"))

(define path (string-append lsp-test/servers:project "/c.fk"))

(lsp-test/servers:write-file! path "(define (f x)\n")

(define (edit line from to text)
  `(("range" ("start" ("line" . ,line) ("character" . ,from)) ("end" ("line" . ,line) ("character" . ,to))) ("newText" . ,text)))

(define (answer! . edits)
  (lsp-test/servers:configure! "shaper" '(capabilities ("textDocumentSync" . 2) ("documentOnTypeFormattingProvider" ("firstTriggerCharacter" . "\n")))
    `(responses ("textDocument/onTypeFormatting" . ,(list->vector edits)))
    '(name . "shaper")))

(define (answer-later! seconds . edits)
  (lsp-test/servers:configure! "shaper" '(capabilities ("textDocumentSync" . 2) ("documentOnTypeFormattingProvider" ("firstTriggerCharacter" . "\n")))
    `(responses ("textDocument/onTypeFormatting" . (delay ,seconds ,(list->vector edits))))
    '(name . "shaper")))

(answer! (edit 1 0 0 "  "))

(tables:set! lsp:language-servers "fakelang" (list shaper))

(hooks:add! lsp-test/servers:fake-mode-hook lsp:ensure)

(define c (lsp-test/servers:visit! path))

(lsp-test/servers:wait-for "shaper" "textDocument/didOpen")

(define (around v)
  (let ([doc (buffers:document c)] [p (views:point v)])
    (list (document:text doc 0 p) (document:text doc p (document:length doc)))))

(define (ret! answered)
  (let ([version (buffers:version c)])
    (test-user:press! "RET")
    (lsp-test/servers:wait-for "shaper" "textDocument/onTypeFormatting" answered)
    (test-runner:wait-until (lambda () (not (= (+ version 1) (buffers:version c)))))))

(define (fresh! content before)
  (buffers:replace! c 1 (- (document:length (buffers:document c)) 1) content)
  (views:set-point! (lsp-test/servers:view) (+ 1 (string-length before))))

(test "on-type formatting is off by default: RET asks the server nothing"
  (views:set-point! (lsp-test/servers:view) (+ 1 (string-length "(define (f x)")))
  (let ([changes (length (lsp-test/servers:of-method "shaper" "textDocument/didChange"))])
    (test-user:press! "RET")
    (lsp-test/servers:wait-for "shaper" "textDocument/didChange" (+ changes 1))
    (check-equal? '(("(define (f x)\n" "\n") 0) (list (around (lsp-test/servers:view)) (length (lsp-test/servers:of-method "shaper" "textDocument/onTypeFormatting")))))
  (options:set! lsp:on-type-formatting? #t))

(test "RET at the end of a line: the server inserts the new line's indentation at point, and point ends after it"
  (fresh! "(define (f x)\n" "(define (f x)")
  (ret! 1)
  (check-equal? '("(define (f x)\n  " "\n") (around (lsp-test/servers:view))))

(test "RET in the middle of a line: point ends after the indentation, before the text that followed, whether the server inserts the indentation, replaces the whole line or sends several edits on it"
  (fresh! "(define (g y)(+ y 1))\n" "(define (g y)")
  (ret! 2)
  (check-equal? '("(define (g y)\n  " "(+ y 1))\n") (around (lsp-test/servers:view)))
  (answer! (edit 1 0 8 "  (+ y 1))"))
  (fresh! "(define (g y)(+ y 1))\n" "(define (g y)")
  (ret! 3)
  (check-equal? '("(define (g y)\n  " "(+ y 1))\n") (around (lsp-test/servers:view)))
  (answer! (edit 1 0 0 "  ") (edit 1 5 7 " ") (edit 1 8 11 " "))
  (fresh! "(define (h z)(list  z   1))\n" "(define (h z)")
  (ret! 4)
  (check-equal? '("(define (h z)\n  " "(list z 1))\n") (around (lsp-test/servers:view))))

(test "RET before a space: the server rewrites the new line's leading space as its indentation, and point, in that whitespace, ends at the end of the new indentation"
  (answer! (edit 2 0 1 "     "))
  (fresh! "(define (f x)\n  (+ x 1))\n" "(define (f x)\n  (+ x")
  (ret! 5)
  (check-equal? '("(define (f x)\n  (+ x\n     " "1))\n") (around (lsp-test/servers:view))))

(test "every view's cursors are carried: a point where the server inserted ends after the insertion, a mark there stays before it, and a mark elsewhere keeps its place"
  (answer-later! 0.3 (edit 1 0 0 "  "))
  (fresh! "(define (k w)\n" "(define (k w)")
  (let* ([v1 (lsp-test/servers:view)] [v2 (layout-split:split-view! v1 (layout-split:direction row))])
    (layout:select! v1)
    (test-user:press! "RET")
    (lsp-test/servers:wait-for "shaper" "textDocument/onTypeFormatting" 6)
    (views:set-mark! v1 1)
    (views:set-point! v2 (views:point v1))
    (views:set-mark! v2 (views:point v1))
    (let ([version (buffers:version c)])
      (test-runner:wait-until (lambda () (not (= version (buffers:version c))))))
    (check-equal? '(("(define (k w)\n  " "\n") 1 ("(define (k w)\n  " "\n") 2)
                  (list (around v1) (views:mark v1) (around v2) (- (views:point v2) (views:mark v2))))
    (layout:select! v2)
    (test-user:press! "C-x 0")))

(test "with an indenter for its mode, RET indents in its own command, so on-type formatting asks nothing; a line break inserted after it by code asks, and is the only break asked about"
  (tables:set! indentation:indenters lsp-test/servers:fake-mode
    (lambda (buffer position) (if (= (document:line (buffers:document buffer) position) 1) 0 2)))
  (answer!)
  (fresh! "(define (m v)\n" "(define (m v)")
  (let ([asked (length (lsp-test/servers:of-method "shaper" "textDocument/onTypeFormatting"))])
    (test-user:press! "RET")
    (check-equal? '("(define (m v)\n  " "\n") (around (lsp-test/servers:view)))
    (let ([end (- (document:length (buffers:document c)) 1)]) (buffers:replace! c end end "\n"))
    (lsp-test/servers:wait-for "shaper" "textDocument/onTypeFormatting" (+ asked 1))
    (check-equal? '(3) (map (lambda (m) (lsp-test/servers:ref m "params" "position" "line"))
                            (list-tail (lsp-test/servers:of-method "shaper" "textDocument/onTypeFormatting") asked))))
  (tables:remove! indentation:indenters lsp-test/servers:fake-mode))
