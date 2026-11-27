(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (timers) (keys) (buffers) (document) (views)
        (layout) (files) (minibuffer) (completion) (completion-list) (diagnostics) (docs-at-point) (lsp) (servers))

(options:set! lsp:send-changes-delay 0.05)

(keys:bind! keys:global "C-c a" lsp:code-actions)

(lsp:define-server types (servers:fake-command "types"))

(lsp:define-server lint (servers:fake-command "lint"))

(define a-path (string-append servers:project "/a.fk"))

(servers:write-file! a-path "import os\nx = 1\n")

(servers:configure! "types" '(capabilities ("textDocumentSync" . 2)) '(name . "types"))

(tables:set! lsp:language-servers "fakelang" (list types))

(hooks:add! servers:fake-mode-hook lsp:ensure)

(define a (servers:visit! a-path))

(servers:wait-for "types" "textDocument/didOpen")

(define (diagnostic line from to message)
  `(("range" ("start" ("line" . ,line) ("character" . ,from)) ("end" ("line" . ,line) ("character" . ,to)))
    ("severity" . 2) ("message" . ,message) ("source" . "types")))

(define (publish! c uri version . diagnostics)
  (servers:send! c `(("jsonrpc" . "2.0") ("method" . "textDocument/publishDiagnostics")
                     ("params" ("uri" . ,uri) ,@(if version `(("version" . ,version)) '()) ("diagnostics" . ,(list->vector diagnostics))))))

(define (seen b)
  (map (lambda (d) (list (diagnostics:diagnostic-message d) (document:text (buffers:document b) (diagnostics:diagnostic-start d) (diagnostics:diagnostic-end d))))
       (diagnostics:in b)))

(define (choices)
  (let ([s (views:call-with-view (servers:view) completion:current-session)])
    (test-runner:wait-until (lambda () (not (completion:session-busy? s))))
    (let ([ms (completion:session-matches s)])
      (map (lambda (k) (completion:text s (completion:matches-ref ms k))) (iota (completion:matches-count ms))))))

(test "a report about an old version is counted on that version's text, so a line typed above since leaves the mark on the line the server meant; the origin is the server's source"
  (let ([then (buffers:version a)])
    (buffers:replace! a 1 1 "# new line\n")
    (publish! (car (lsp:connections)) (lsp:path->uri a-path) then (diagnostic 0 7 9 "\"os\" is not accessed"))
    (test-runner:wait-until (lambda () (pair? (diagnostics:in a))))
    (check-equal? '(("\"os\" is not accessed" "os")) (seen a))
    (check-equal? '("types") (map diagnostics:diagnostic-origin (diagnostics:in a)))))

(test "lsp:ensure turns diagnostics:mode on in a managed buffer, and sets docs-at-point:all locally"
  (buffers:with-buffer a
    (check-equal? (list #t docs-at-point:all) (list (diagnostics:mode) (docs-at-point:strategy)))))

(test "a diagnostic of a file no buffer visits has its columns read from the file, here UTF-8 bytes after non-ASCII text; a shut-down server's diagnostics go"
  (lsp:shutdown (car (lsp:connections)))
  (check-equal? '() (diagnostics:in a))
  (servers:configure! "types" '(capabilities ("textDocumentSync" . 2) ("positionEncoding" . "utf-8")) '(name . "types"))
  (buffers:with-buffer a (lsp:ensure))
  (test-runner:wait-until (lambda () (= 2 (length (servers:of-method "types" "textDocument/didOpen")))))
  (let ([u-path (string-append servers:project "/u.fk")])
    (servers:write-file! u-path "café = total\n")
    (publish! (car (lsp:connections)) (lsp:path->uri u-path) #f (diagnostic 0 8 13 "undefined"))
    (test-runner:wait-until (lambda () (pair? (diagnostics:under servers:project))))
    (check-equal? '(((1 . 7) (1 . 12)))
                  (map (lambda (d) (list (diagnostics:diagnostic-start d) (diagnostics:diagnostic-end d)))
                       (filter (lambda (d) (equal? (diagnostics:diagnostic-path d) u-path)) (diagnostics:under servers:project))))))

(test "a server that offers pulled diagnostics is asked when the buffer opens and after each change sent"
  (servers:configure! "lint" '(capabilities ("textDocumentSync" . 2) ("diagnosticProvider" ("interFileDependencies" . #f) ("workspaceDiagnostics" . #f)))
    '(responses ("textDocument/diagnostic" ("kind" . "full")
                 ("items" . #((("range" ("start" ("line" . 1) ("character" . 0)) ("end" ("line" . 1) ("character" . 6))) ("severity" . 1) ("message" . "F401") ("source" . "Ruff"))))))
    '(name . "lint"))
  (tables:set! lsp:language-servers "fakelang" (list types lint))
  (buffers:with-buffer a (lsp:ensure))
  (servers:wait-for "lint" "textDocument/didOpen")
  (buffers:replace! a 1 1 "")
  (buffers:replace! a 1 1 "#")
  (servers:wait-for "lint" "textDocument/diagnostic" 2)
  (test-runner:wait-until (lambda () (assoc "F401" (seen a))))
  (check-equal? '(("F401" "import")) (seen a))
  (buffers:replace! a 1 2 "")
  (servers:wait-for "lint" "textDocument/diagnostic" 3)
  (check-equal? '(2 3) (list (length (servers:of-method "lint" "textDocument/didChange")) (length (servers:of-method "lint" "textDocument/diagnostic")))))

(define (action title . more) (append `(("title" . ,title) ("kind" . "quickfix")) more))

(define (insert-edit text)
  `(("changes" (,(lsp:path->uri a-path) . #((("range" ("start" ("line" . 0) ("character" . 0)) ("end" ("line" . 0) ("character" . 0))) ("newText" . ,text)))))))

(define (reconnect-all!)
  (let ([opened (map (lambda (n) (length (servers:of-method n "textDocument/didOpen"))) '("types" "lint"))])
    (for-each lsp:reconnect (lsp:connections))
    (for-each (lambda (n count) (servers:wait-for n "textDocument/didOpen" (+ count 1))) '("types" "lint") opened)
    (test-runner:wait-until (lambda () (= 2 (length (lsp:buffer-connections a)))))))

(test "code actions from every server are merged and labelled by server, the preferred first; one without an edit is resolved first"
  (servers:configure! "types" `(capabilities ("textDocumentSync" . 2) ("positionEncoding" . "utf-8") ("codeActionProvider" ("resolveProvider" . #t)))
    `(responses ("textDocument/codeAction" . #(,(action "Remove import") ,(action "Ignore" '("isPreferred" . #t))))
                ("codeAction/resolve" . ,(action "Remove import" (cons "edit" (insert-edit "R")))))
    '(name . "types"))
  (servers:configure! "lint" `(capabilities ("textDocumentSync" . 2) ("codeActionProvider" . #t))
    `(responses ("textDocument/codeAction" . #(,(action "Fix all" (cons "edit" (insert-edit "F"))))))
    '(name . "lint"))
  (reconnect-all!)
  (servers:press-until-prompt! "C-c a")
  (check-equal? '("Ignore (types)" "Remove import (types)" "Fix all (lint)") (choices))
  (servers:press-until-ended! "C-n RET" lsp:code-actions)
  (check-equal? '("R# new line\nimport os\nx = 1\n" 1) (list (servers:text a) (length (servers:of-method "types" "codeAction/resolve")))))

(test "C-u asks for the kind, offering five and taking any typed, which goes as the request's only"
  (test-user:press! "C-u C-c a")
  (check-equal? "Action kind: " (servers:question))
  (check-equal? '("quickfix" "refactor.inline" "refactor.extract" "refactor.rewrite" "source.organizeImports") (choices))
  (test-user:type! "refactor.extract")
  (servers:press-until-prompt! "RET")
  (check-equal? '(cancelled) (servers:reports-during (lambda () (test-user:press! "C-g"))))
  (check-equal? '#("refactor.extract") (servers:ref (servers:last-of "types" "textDocument/codeAction") "params" "context" "only")))

(test "a connection that a reconnect replaces while the code-action hint asks the others gives the hint nothing, and the hint does not fail"
  (servers:configure! "types" `(capabilities ("textDocumentSync" . 2) ("codeActionProvider" . #t))
    `(responses ("textDocument/codeAction" . (delay 0.5 #(,(action "Slow")))))
    '(name . "types"))
  (reconnect-all!)
  (let ([hint-source (diagnostics:make-source)])
    (diagnostics:report! hint-source a (list (diagnostics:make-diagnostic 1 3 (diagnostics:severity warning) "here")))
    (views:set-point! (servers:view) 2)
    (let ([asked (spawn-task (lambda (restore) (lsp:code-action-hint (servers:view))))])
      (lsp:reconnect (cadr (lsp:buffer-connections a)))
      (check-equal? "Slow (C-c a)" (docs-at-point:doc-text (test-runner:join asked))))))

(test "a reconnect leaves the buffer one docs entry of each kind per connection, not the replaced connection's as well"
  (let ([sources (lambda () (length (buffers:with-buffer a (hooks:entries docs-at-point:sources))))])
    (test-runner:wait-until (lambda () (= 2 (length (lsp:buffer-connections a)))))
    (let ([before (sources)])
      (reconnect-all!)
      (check-equal? before (sources)))))
