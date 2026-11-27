(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (timers) (buffers) (document) (views) (layout)
        (files) (completion) (completion-list) (layout-float) (completion-popup) (lsp) (lsp-test servers))

(options:set! lsp:send-changes-delay 0.05)

(lsp:define-server alpha (lsp-test/servers:fake-command "alpha"))

(define (item label) `(("label" . ,label)))

(define (configure-completion! result)
  (lsp-test/servers:configure! "alpha"
    '(capabilities ("textDocumentSync" . 2) ("completionProvider" ("triggerCharacters" . #("."))) ("executeCommandProvider" ("commands" . #("server.cmd"))))
    `(responses ("textDocument/completion" . ,result))))

(configure-completion! (vector (item "apple") (item "apricot") (item "banana")))

(tables:set! lsp:language-servers "fakelang" (list alpha))

(hooks:add! lsp-test/servers:fake-mode-hook lsp:ensure)

(lsp-test/servers:write-file! (string-append lsp-test/servers:project "/a.fk") "\n")

(define a (lsp-test/servers:visit! (string-append lsp-test/servers:project "/a.fk")))

(lsp-test/servers:wait-for "alpha" "textDocument/didOpen")

(define (session) (views:call-with-view (lsp-test/servers:view) completion:current-session))

(define (texts)
  (let ([s (session)])
    (test-runner:wait-until (lambda () (not (completion:session-busy? s))))
    (let ([ms (completion:session-matches s)])
      (map (lambda (k) (completion:text s (completion:matches-ref ms k))) (iota (completion:matches-count ms))))))

(define (complete!)
  (test-user:press! "C-M-i")
  (test-runner:wait-until (lambda () (session))))

(test "a complete list is asked once and filtered as typing goes on"
  (test-user:type! "ap")
  (complete!)
  (check-equal? '("apple" "apricot") (texts))
  (test-user:type! "r")
  (check-equal? '(("apricot") 1) (list (texts) (length (lsp-test/servers:of-method "alpha" "textDocument/completion"))))
  (test-user:press! "M-n RET")
  (check-equal? "apricot\n" (lsp-test/servers:text a)))

(test "an incomplete list is asked again at each change of the input"
  (configure-completion! '(("isIncomplete" . #t) ("items" . #((("label" . "cherry")) (("label" . "chestnut"))))))
  (test-user:press! "RET")
  (test-user:type! "ch")
  (complete!)
  (texts)
  (test-user:type! "e")
  (texts)
  (check-equal? 3 (length (lsp-test/servers:of-method "alpha" "textDocument/completion")))
  (test-user:press! "C-g"))

(define ran '())

(define (fresh!)
  (buffers:replace! a 1 (- (document:length (buffers:document a)) 1) "x\nda\n")
  (views:set-point! (lsp-test/servers:view) 5))

(test "a text edit is counted on the text the request saw, so it applies after more typing; extra edits, such as an import, and a command follow"
  (tables:set! lsp:commands "server.cmd" (lambda (c arguments) (set! ran (cons (vector->list arguments) ran))))
  (configure-completion!
    (vector `(("label" . "datetime")
              ("textEdit" ("range" ("start" ("line" . 1) ("character" . 0)) ("end" ("line" . 1) ("character" . 2))) ("newText" . "datetime.now"))
              ("additionalTextEdits" . #((("range" ("start" ("line" . 0) ("character" . 0)) ("end" ("line" . 0) ("character" . 0))) ("newText" . "import datetime\n"))))
              ("command" ("title" . "x") ("command" . "server.cmd") ("arguments" . #(1 2))))))
  (fresh!)
  (complete!)
  (texts)
  (test-user:type! "t")
  (texts)
  (test-user:press! "M-n RET")
  (test-runner:wait-until (lambda () (pair? ran)))
  (check-equal? '("import datetime\nx\ndatetime.now\n" ((1 2))) (list (lsp-test/servers:text a) ran)))

(test "without a local procedure a command goes to the server"
  (tables:remove! lsp:commands "server.cmd")
  (fresh!)
  (complete!)
  (texts)
  (test-user:press! "M-n RET")
  (lsp-test/servers:wait-for "alpha" "workspace/executeCommand")
  (check-equal? '(("command" . "server.cmd") ("arguments" . #(1 2))) (lsp-test/servers:ref (lsp-test/servers:last-of "alpha" "workspace/executeCommand") "params")))

(test "a server's trigger character starts completion as soon as it is typed, with no text before point, where a symbol's first character starts none"
  (options:set! completion-popup:auto-delay 0.01)
  (configure-completion! (vector (item "now") (item "today")))
  (buffers:replace! a 1 (- (document:length (buffers:document a)) 1) "\n")
  (views:set-point! (lsp-test/servers:view) 1)
  (test-user:type! "d")
  ;; The claim is that a letter starts no completion, so the check waits
  ;; well past the popup's delay first.
  (timers:sleep 0.2)
  (check-equal? #f (session))
  (test-user:type! ".")
  (test-runner:wait-until (lambda () (session)))
  (check-equal? '("now" "today") (texts))
  (test-user:press! "C-g")
  (options:unset! completion-popup:auto-delay))
