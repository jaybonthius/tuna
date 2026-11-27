(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (keys) (buffers) (document) (views) (layout)
        (files) (minibuffer) (completion) (completion-list) (echo-area) (diagnostics) (docs-at-point) (docs-at-point-display)
        (lsp) (lsp-test servers))

(options:set! lsp:send-changes-delay 0.05 docs-at-point:delay 0.05)

(keys:bind! keys:global "C-c a" lsp:code-actions)

(keys:bind! keys:global "C-c r" lsp:rename)

(lsp:define-server types (lsp-test/servers:fake-command "types"))

(define a-path (string-append lsp-test/servers:project "/a.fk"))

(define b-path (string-append lsp-test/servers:project "/b.fk"))

(lsp-test/servers:write-file! a-path "total = 1\nprint(total)\n")

(lsp-test/servers:write-file! b-path "from a import total\n")

(define (edit-at path line from to text)
  `(,(lsp:path->uri path) . #((("range" ("start" ("line" . ,line) ("character" . ,from)) ("end" ("line" . ,line) ("character" . ,to))) ("newText" . ,text)))))

(lsp-test/servers:configure! "types"
  `(capabilities ("textDocumentSync" . 2) ("renameProvider" ("prepareProvider" . #t)) ("documentFormattingProvider" . #t)
                 ("codeActionProvider" . #t) ("documentOnTypeFormattingProvider" ("firstTriggerCharacter" . ":")))
  `(responses ("textDocument/prepareRename" ("start" ("line" . 0) ("character" . 0)) ("end" ("line" . 0) ("character" . 5)))
              ("textDocument/rename" ("changes" ,(edit-at a-path 0 0 5 "sum") ,(edit-at b-path 0 14 19 "sum")))
              ("textDocument/formatting"
               . (delay 0.4 #((("range" ("start" ("line" . 0) ("character" . 0)) ("end" ("line" . 0) ("character" . 0))) ("newText" . "# formatted\n")))))
              ("textDocument/codeAction" . #((("title" . "Use sum") ("kind" . "quickfix") ("isPreferred" . #t)
                                              ("edit" ("changes" ,(edit-at a-path 1 6 11 "sum")))))))
  '(name . "types"))

(tables:set! lsp:language-servers "fakelang" (list types))

(hooks:add! lsp-test/servers:fake-mode-hook lsp:ensure)

(define a (lsp-test/servers:visit! a-path))

(lsp-test/servers:wait-for "types" "textDocument/didOpen")

(test "rename asks, quoting the identifier, with the server's text under M-n; an edit that changes an unopened file asks first, and no applies nothing"
  (views:set-point! (lsp-test/servers:view) 2)
  (lsp-test/servers:press-until-prompt! "C-c r")
  (check-equal? '("Rename `total' to: " "") (list (lsp-test/servers:question) (lsp-test/servers:input)))
  (test-user:press! "M-n")
  (check-equal? "total" (lsp-test/servers:input))
  (test-user:press! "C-a C-k")
  (test-user:type! "sum")
  (lsp-test/servers:press-until-prompt! "RET")
  (check-equal? (format "Apply changes to ~a, ~a? (yes or no) " (files:abbreviated-path a-path) (files:abbreviated-path b-path)) (lsp-test/servers:question))
  (test-user:type! "no")
  (check-equal? '((lsp "Changes not applied")) (lsp-test/servers:reports-during (lambda () (lsp-test/servers:press-until-ended! "RET" lsp:rename))))
  (check-equal? "total = 1\nprint(total)\n" (lsp-test/servers:text a)))

(test "with lsp:confirm-edits never, a rename changes an open and an unopened file without asking"
  (options:set! lsp:confirm-edits (lsp:confirmation never))
  (views:call-with-view (lsp-test/servers:view) (lambda () (lsp:rename "sum")))
  (check-equal? '("sum = 1\nprint(total)\n" "from a import sum\n") (list (lsp-test/servers:text a) (lsp-test/servers:text (files:buffer-visiting b-path))))
  (options:unset! lsp:confirm-edits))

(test "a format answered after the user typed is refused, and nothing changes"
  (let* ([asked (length (lsp-test/servers:of-method "types" "textDocument/formatting"))]
         [t (spawn-task (lambda (restore)
                          (guard (c [(error? c) (condition-message c)])
                            (views:call-with-view (lsp-test/servers:view) (lambda () (lsp:format-buffer a))))))])
    (lsp-test/servers:wait-for "types" "textDocument/formatting" (+ asked 1))
    (buffers:replace! a 1 1 "x")
    (check-equal? "a.fk changed while types answered" (test-runner:join t)))
  (check-equal? "xsum = 1\nprint(total)\n" (lsp-test/servers:text a)))

(test "as a files:before-save entry, it formats each save, which waits for it"
  (buffers:with-buffer a (hooks:add-local! files:before-save lsp:format-buffer))
  (views:call-with-view (lsp-test/servers:view) (lambda () (files:save-buffer a)))
  (check-equal? "# formatted\nxsum = 1\nprint(total)\n" (call-with-input-file a-path get-string-all))
  (buffers:with-buffer a (hooks:remove-local! files:before-save lsp:format-buffer)))

(lsp-test/servers:configure! "types"
  `(capabilities ("textDocumentSync" . 2) ("documentOnTypeFormattingProvider" ("firstTriggerCharacter" . ":")) ("codeActionProvider" . #t))
  `(responses ("textDocument/onTypeFormatting" . #((("range" ("start" ("line" . 0) ("character" . 0)) ("end" ("line" . 0) ("character" . 0))) ("newText" . "  "))))
              ("textDocument/codeAction" . #((("title" . "Use sum") ("kind" . "quickfix") ("isPreferred" . #t)
                                              ("edit" ("changes" ,(edit-at a-path 2 6 11 "sum"))))))
              ("window/showMessageRequest" . null))
  '(name . "types"))

(define c #f)

(test "once on, on-type formatting asks the server for edits when a character it names is typed, and applies them"
  (lsp:reconnect (car (lsp:connections)))
  (lsp-test/servers:wait-for "types" "initialize" 2)
  (set! c (car (lsp:connections)))
  (test-runner:wait-until (lambda () (lsp:connection-capability c "documentOnTypeFormattingProvider")))
  (options:set! lsp:on-type-formatting? #t)
  (views:set-point! (lsp-test/servers:view) 1)
  (test-user:type! ":")
  (lsp-test/servers:wait-for "types" "textDocument/onTypeFormatting")
  (check-equal? `(("textDocument" ("uri" . ,(lsp:path->uri a-path))) ("position" ("line" . 0) ("character" . 1)) ("ch" . ":")
                  ("options" ("tabSize" . 8) ("insertSpaces" . #t)))
                (lsp-test/servers:ref (lsp-test/servers:last-of "types" "textDocument/onTypeFormatting") "params"))
  (test-runner:wait-until (lambda () (equal? "  :#" (substring (lsp-test/servers:text a) 0 4))))
  (options:unset! lsp:on-type-formatting?))

(define at #f)

(test "<mouse-2> on a server's diagnostic runs its code actions there; on a checker's, nothing lsp binds runs"
  (lsp-test/servers:publish! c a-path
    (list '(("range" ("start" ("line" . 2) ("character" . 6)) ("end" ("line" . 2) ("character" . 11))) ("severity" . 2) ("message" . "use sum"))))
  (test-runner:wait-until (lambda () (pair? (diagnostics:in a))))
  (set! at (diagnostics:diagnostic-start (car (diagnostics:in a))))
  (test-user:settle)
  (test-user:click! (lsp-test/servers:view) (+ at 1) "<mouse-2>")
  (test-runner:wait-until (lambda () (equal? "sum" (document:text (buffers:document a) at (+ at 3)))))
  (check-equal? 1 (length (lsp-test/servers:of-method "types" "textDocument/codeAction")))
  (let ([checker (diagnostics:make-source)])
    (diagnostics:report! checker a (list (diagnostics:make-diagnostic 2 4 (diagnostics:severity info) "a checker's")))
    (test-user:settle)
    (test-user:click! (lsp-test/servers:view) 2 "<mouse-2>")
    (check-equal? 1 (length (lsp-test/servers:of-method "types" "textDocument/codeAction")))))

(test "the hint names the one action at a diagnostic and the key that runs it, which then runs it without asking"
  (lsp-test/servers:publish! c a-path
    (list '(("range" ("start" ("line" . 0) ("character" . 2)) ("end" ("line" . 0) ("character" . 3))) ("severity" . 2) ("message" . "colon"))))
  (test-runner:wait-until (lambda () (exists (lambda (d) (equal? "colon" (diagnostics:diagnostic-message d))) (diagnostics:in a))))
  (views:set-point! (lsp-test/servers:view) 3)
  (docs-at-point:ask-sources (lsp-test/servers:view))
  (test-runner:wait-until (lambda () (equal? "Use sum (C-c a)\na checker's\ntypes: colon" (echo-area:current-message))))
  (let ([asked (length (lsp-test/servers:of-method "types" "textDocument/codeAction"))])
    (lsp-test/servers:press-until-ended! "C-c a" lsp:code-actions)
    (check-equal? asked (length (lsp-test/servers:of-method "types" "textDocument/codeAction")))))

(test "the hint asks as a background request, triggerKind 2; a command asks with 1, as invoked"
  (check-equal? '(1 2) (map (lambda (m) (lsp-test/servers:ref m "params" "context" "triggerKind")) (lsp-test/servers:of-method "types" "textDocument/codeAction"))))

(test "with lsp:code-action-hint? off, the hint asks nothing"
  (let ([asked (length (lsp-test/servers:of-method "types" "textDocument/codeAction"))])
    (options:set! lsp:code-action-hint? #f)
    (check-equal? #f (lsp:code-action-hint (lsp-test/servers:view)))
    (options:unset! lsp:code-action-hint?)
    (check-equal? asked (length (lsp-test/servers:of-method "types" "textDocument/codeAction")))))

(test "a server's showMessageRequest asks with ask:choice and answers the action chosen"
  (lsp-test/servers:send! c '(("jsonrpc" . "2.0") ("id" . "m1") ("method" . "window/showMessageRequest")
                     ("params" ("type" . 3) ("message" . "Install stubs?") ("actions" . #((("title" . "Yes")) (("title" . "No")))))))
  (test-runner:wait-until (lambda () (minibuffer:current-prompt)))
  (test-user:settle)
  (test-user:press! "C-n RET")
  (test-runner:wait-until (lambda () (lsp-test/servers:answered "types" "m1")))
  (check-equal? '(("title" . "No")) (lsp-test/servers:ref (lsp-test/servers:answered "types" "m1") "result")))

(lsp-test/servers:configure! "types" '(capabilities ("textDocumentSync" . 2) ("renameProvider" ("prepareProvider" . #t)))
  '(responses ("textDocument/prepareRename" . null))
  '(name . "types"))

(test "a server that answers prepareRename with nothing refuses before any name is asked"
  (lsp:reconnect (car (lsp:connections)))
  (lsp-test/servers:wait-for "types" "initialize" 3)
  (test-runner:wait-until (lambda () (and (pair? (lsp:connections)) (lsp:connection-capability (car (lsp:connections)) "renameProvider"))))
  (check-equal? '((lsp:rename "Can't rename here")) (lsp-test/servers:reports-during (lambda () (lsp-test/servers:press-until-ended! "C-c r" lsp:rename)))))
