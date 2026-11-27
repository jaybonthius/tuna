(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (keys) (buffers) (document) (views) (layout)
        (files) (xref) (jump-history) (minibuffer) (completion) (completion-list) (echo-area) (faces) (docs-at-point)
        (docs-at-point-display) (lsp) (servers))

(options:set! lsp:send-changes-delay 0.05 lsp:highlight-delay 0.05 docs-at-point:delay 0.05)

(lsp:define-server types (servers:fake-command "types") (capabilities '(("experimental" ("tunaTest" . #t)))))

(lsp:define-server style (servers:fake-command "style"))

(define (location path line from to)
  `(("uri" . ,(lsp:path->uri path)) ("range" ("start" ("line" . ,line) ("character" . ,from)) ("end" ("line" . ,line) ("character" . ,to)))))

(define a-path (string-append servers:project "/a.fk"))

(define b-path (string-append servers:project "/b.fk"))

(servers:write-file! a-path "total(1)\n")

(servers:write-file! b-path "x\ndef total(n):\n")

(servers:configure! "types"
  `(capabilities ("textDocumentSync" . 2) ("definitionProvider" . #t) ("hoverProvider" . #t) ("signatureHelpProvider" ("triggerCharacters" . #("("))))
  `(responses ("textDocument/definition" . #(,(location b-path 1 4 9)))
              ("textDocument/hover" . (("contents" ("kind" . "markdown") ("value" . "total: types")))))
  '(name . "types"))

(servers:configure! "style"
  `(capabilities ("textDocumentSync" . 2) ("definitionProvider" . #t) ("hoverProvider" . #t))
  `(responses ("textDocument/definition" . #(,(location a-path 0 0 5)))
              ("textDocument/hover" . (delay 0.5 (("contents" . "total: style")))))
  '(name . "style"))

(tables:set! lsp:language-servers "fakelang" (list types style))

(hooks:add! servers:fake-mode-hook lsp:ensure)

(define a (servers:visit! a-path))

(servers:wait-for "types" "textDocument/didOpen")

(servers:wait-for "style" "textDocument/didOpen")

(define (choices)
  (let ([s (views:call-with-view (servers:view) completion:current-session)])
    (test-runner:wait-until (lambda () (not (completion:session-busy? s))))
    (let ([ms (completion:session-matches s)])
      (map (lambda (k) (completion:text s (completion:matches-ref ms k))) (iota (completion:matches-count ms))))))

(define (reconnect! name)
  (let ([opened (length (servers:of-method name "textDocument/didOpen"))])
    (lsp:reconnect (find (lambda (c) (equal? (lsp:connection-title c) name)) (lsp:buffer-connections a)))
    (servers:wait-for name "textDocument/didOpen" (+ opened 1))
    (test-runner:wait-until (lambda () (= 2 (length (lsp:buffer-connections a)))))))

(test "a server's capabilities clause is merged into what initialize offers"
  (check-equal? '(("tunaTest" . #t)) (servers:ref (servers:last-of "types" "initialize") "params" "capabilities" "experimental")))

(test "definitions from both servers are merged; M-. asks between them, and the one in a file no buffer visits shows its line, read from the file"
  (views:set-point! (servers:view) 2)
  (servers:press-until-prompt! "M-.")
  (check-equal? '("~/project/b.fk:2: def total(n):" "~/project/a.fk:1: total(1)") (choices))
  (servers:press-until-ended! "RET" xref:find-definitions)
  (check-equal? '("b.fk" 7) (list (buffers:name (views:buffer (servers:view))) (views:point (servers:view))))
  (test-user:press! "M-,"))

(test "each server's hover is a docs source of its own, so the slow server's does not hold back the fast one's"
  (docs-at-point:ask-sources (servers:view))
  (test-runner:wait-until (lambda () (equal? "total: types" (echo-area:current-message))))
  (test-runner:wait-until (lambda () (equal? "total: types\ntotal: style" (echo-area:current-message)))))

(test "a signature shows with its active parameter in the highlight face"
  (servers:configure! "types" `(capabilities ("textDocumentSync" . 2) ("signatureHelpProvider" ("triggerCharacters" . #("("))))
    '(responses ("textDocument/signatureHelp" ("signatures" . #((("label" . "total(items, start)") ("parameters" . #((("label" . "items")) (("label" . #(13 18))))))))
                 ("activeSignature" . 0) ("activeParameter" . 1)))
    '(name . "types"))
  (servers:configure! "style" '(capabilities ("textDocumentSync" . 2)) '(name . "style"))
  (reconnect! "types")
  (reconnect! "style")
  (docs-at-point:ask-sources (servers:view))
  (test-runner:wait-until (lambda () (equal? "total(items, start)" (echo-area:current-message))))
  (check-equal? (list (list 13 18 faces:highlight)) (echo-area:current-spans)))

(define (lit)
  (let ([l (find (lambda (l) (= (buffers:layer-priority l) 5)) (buffers:layers a (servers:view)))])
    (if l
        (map (lambda (s) (list (car s) (cadr s) (cdr (assq 'face (caddr s))))) (buffers:spans l 0 (document:length (buffers:document a))))
        '())))

(test "highlights come after the idle delay, from the first server that gives them, and the next command clears them; they come with docs-at-point off too"
  (servers:configure! "types" '(capabilities ("textDocumentSync" . 2) ("documentHighlightProvider" . #t))
    '(responses ("textDocument/documentHighlight" . #((("range" ("start" ("line" . 0) ("character" . 0)) ("end" ("line" . 0) ("character" . 5)))))))
    '(name . "types"))
  (reconnect! "types")
  (options:set! docs-at-point:mode #f)
  (test-user:press! "C-a")
  (check-equal? '() (lit))
  (test-runner:wait-until (lambda () (pair? (lit))))
  (check-equal? '((1 6 (lsp.highlight highlight))) (lit))
  (test-user:press! "C-f")
  (check-equal? '() (lit))
  (options:unset! docs-at-point:mode))

(test "a hover is Markdown whose echo is the first line it shows, a fence's marks left out"
  (servers:configure! "types" '(capabilities ("textDocumentSync" . 2) ("hoverProvider" . #t))
    '(responses ("textDocument/hover" ("contents" ("kind" . "markdown") ("value" . "```python\ndef total(items) -> int\n```\n---\nSums the items."))))
    '(name . "types"))
  (reconnect! "types")
  (let ([doc (lsp:hover (car (lsp:buffer-connections a)) (servers:view))])
    (check-equal? '(#t "def total(items) -> int") (list (docs-at-point:doc-markdown? doc) (docs-at-point:doc-echo doc)))))
