(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (keys) (buffers) (document) (views) (layout)
        (files) (xref) (jsonrpc) (minibuffer) (completion) (completion-list) (lsp) (servers))

(options:set! lsp:send-changes-delay 0.05)

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

(define managed '())

(define connected '())

(hooks:add! lsp:managed (lambda (b) (set! managed (cons (list b (lsp:managed? b) (buffers:current)) managed))))

(hooks:add! lsp:connected (lambda (c) (set! connected (cons c connected))))

(keys:bind! keys:global "C-c a" lsp:code-actions)

(keys:bind! keys:global "C-c q" lsp:quickfix)

(keys:bind! keys:global "C-c o" lsp:organize-imports)

(lsp:define-server alpha (servers:fake-command "alpha"))

(define a-path (string-append servers:project "/a b é.fk"))

(define (edit text)
  `(("changes" (,(lsp:path->uri a-path) . #((("range" ("start" ("line" . 0) ("character" . 0)) ("end" ("line" . 0) ("character" . 0))) ("newText" . ,text)))))))

(define (action title kind . more) (append `(("title" . ,title) ("kind" . ,kind)) more))

(servers:configure! "alpha" '(capabilities ("textDocumentSync" . 2) ("codeActionProvider" . #t)) '(responses ("textDocument/codeAction" . #())))

(tables:set! lsp:language-servers "fakelang" (list alpha))

(hooks:add! servers:fake-mode-hook lsp:ensure)

(servers:write-file! a-path "one\ntwo\n")

(define a (servers:visit! a-path))

(servers:wait-for "alpha" "textDocument/didOpen")

(define c (car (lsp:buffer-connections a)))

(test "lsp:connected is called with a connection once its server has answered initialize, and lsp:managed with the buffer, current, as it is managed"
  (check-equal? (list c) connected)
  (check-equal? (list (list a #t a)) managed))

(test "a connection's title is the name its program reports, else the program's file name; its capabilities are read by keys"
  (check-equal? "fake" (lsp:connection-title c))
  (check-equal? 2 (lsp:connection-capability c "textDocumentSync"))
  (check-equal? #f (lsp:connection-capability c "hoverProvider" "anything"))
  (check (lsp:connection? c))
  (check (jsonrpc:connection? c))
  (check (not (lsp:connection? 'c))))

(test "a path and its file: URI turn into each other, characters outside the unreserved ones escaped; another scheme raises"
  (check-equal? a-path (lsp:uri->path (lsp:path->uri a-path)))
  (check-equal? (string-append "file://" servers:project "/a%20b%20%C3%A9.fk") (lsp:path->uri a-path))
  (check-raises (raised? 'lsp:uri->path "not a file: URI") (lsp:uri->path "https://example.org/a")))

(test "a Location becomes an xref item with its line's text as the summary"
  (let ([item (lsp:location->item c `(("uri" . ,(lsp:path->uri a-path)) ("range" ("start" ("line" . 1) ("character" . 1)) ("end" ("line" . 1) ("character" . 2)))))])
    (check-equal? (list "two" a-path 2 1) (list (xref:item-summary item) (xref:item-path item) (xref:item-line item) (xref:item-column item)))))

(test "a server's showMessage goes to the echo area through ask:message"
  (servers:said!)
  (servers:send! c '(("jsonrpc" . "2.0") ("method" . "window/showMessage") ("params" ("type" . 3) ("message" . "Indexed."))))
  (let ([got '()])
    (test-runner:wait-until (lambda () (set! got (append got (servers:said!))) (member "Indexed." got)))
    (check-equal? '("Indexed.") got)))

(test "a server's request a table entry names is answered by it"
  (tables:set! lsp:request-handlers "fake/ask" (lambda (connection params) (list (cons "echo" params))))
  (servers:send! c '(("jsonrpc" . "2.0") ("id" . "r1") ("method" . "fake/ask") ("params" ("n" . 1))))
  (test-runner:wait-until (lambda () (servers:answered "alpha" "r1")))
  (check-equal? '(("echo" ("n" . 1))) (servers:ref (servers:answered "alpha" "r1") "result")))

(test "lsp:code-actions with none raises No code actions here"
  (check-equal? '((lsp:code-actions "No code actions here")) (servers:reports-during (lambda () (servers:press-until-ended! "C-c a" lsp:code-actions)))))

(test "with several, lsp:code-actions asks Code action:, the preferred first"
  (servers:configure! "alpha" '(capabilities ("textDocumentSync" . 2) ("codeActionProvider" . #t))
    `(responses ("textDocument/codeAction" . #(,(action "Plain" "quickfix" (cons "edit" (edit "P"))) ,(action "Best" "quickfix" '("isPreferred" . #t) (cons "edit" (edit "B")))))))
  (servers:press-until-prompt! "C-c a")
  (check-equal? "Code action: " (servers:question))
  (let* ([s (views:call-with-view (servers:view) completion:current-session)] [ms (begin (test-runner:wait-until (lambda () (not (completion:session-busy? s)))) (completion:session-matches s))])
    (check-equal? '("Best" "Plain") (map (lambda (k) (completion:text s (completion:matches-ref ms k))) (iota (completion:matches-count ms)))))
  (servers:press-until-ended! "RET" lsp:code-actions)
  (check-equal? "Bone\ntwo\n" (servers:text a)))

(test "lsp:quickfix and lsp:organize-imports run their kind's one action without asking"
  (servers:configure! "alpha" '(capabilities ("textDocumentSync" . 2) ("codeActionProvider" . #t))
    `(responses ("textDocument/codeAction" . #(,(action "Fix" "quickfix" (cons "edit" (edit "Q"))) ,(action "Sort" "source.organizeImports" (cons "edit" (edit "O")))))))
  (servers:press-until-ended! "C-c q" lsp:quickfix)
  (check-equal? "QBone\ntwo\n" (servers:text a))
  (servers:press-until-ended! "C-c o" lsp:organize-imports)
  (check-equal? "OQBone\ntwo\n" (servers:text a)))

(test "lsp:execute-command sends a command no lsp:commands entry names to the server"
  (lsp:execute-command c '(("title" . "x") ("command" . "server.do") ("arguments" . #(3))))
  (servers:wait-for "alpha" "workspace/executeCommand")
  (check-equal? '(("command" . "server.do") ("arguments" . #(3))) (servers:ref (servers:last-of "alpha" "workspace/executeCommand") "params")))

(test "lsp:keymap is the keymap of the managed state mode, and empty"
  (check-equal? '() (keys:bindings lsp:keymap)))

(test "lsp:managed is called again as the buffer is released"
  (set! managed '())
  (lsp:shutdown c)
  (test-runner:wait-until (lambda () (pair? managed)))
  (check-equal? (list (list a #f a)) managed))
