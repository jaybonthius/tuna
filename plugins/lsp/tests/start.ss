(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (keys) (buffers) (document) (views) (layout)
        (files) (xref) (jump-history) (minibuffer) (lsp) (lsp-test servers) (lsp-test chez-lsp))

(options:set! lsp:send-changes-delay 0.05)

(keys:bind! keys:global "C-c s" lsp:start)

(define (syntax-error? message)
  (lambda (c) (and (syntax-violation? c) (string=? message (condition-message c)))))

(define (short root) (substring root (string-length lsp-test/servers:home) (string-length root)))

(define (roots) (map (lambda (c) (short (lsp:connection-root c))) (lsp:connections)))

(lsp:define-server alpha (lsp-test/servers:fake-command "alpha"))

(lsp-test/servers:configure! "alpha" '(capabilities ("textDocumentSync" . 2) ("definitionProvider" . #t)) '(name . "alpha"))

(tables:set! lsp:language-servers "fakelang" (list alpha))

(define one (string-append lsp-test/servers:project "/one"))

(lsp-test/servers:write-file! (string-append one "/go.mod") "")
(lsp-test/servers:write-file! (string-append one "/a.fk") "use x\n")
(lsp-test/servers:write-file! (string-append lsp-test/servers:project "/two/x.fk") "def x\n")

(define a (lsp-test/servers:visit! (string-append one "/a.fk")))

(test "C-u lsp:start asks each server's command line, offering the one it has, and starts the buffer's servers with the answer"
  (check (not (lsp:managed? a)))
  (test-user:press! "C-u C-c s")
  (check-equal? (list (format "Command for ~a: " alpha) "") (list (lsp-test/servers:question) (lsp-test/servers:input)))
  (test-user:press! "M-n RET")
  (lsp-test/servers:wait-for "alpha" "textDocument/didOpen")
  (check-equal? (list #t (lsp-test/servers:fake-command "alpha")) (list (lsp:managed? a) (lsp:connection-command (car (lsp:connections))))))

(test "asked again while they run, lsp:start first asks whether to shut them down"
  (test-user:press! "C-c s")
  (check-equal? "Shut down the buffer's servers first? (yes or no) " (lsp-test/servers:question))
  (test-user:type! "no")
  (test-user:press! "RET")
  (check-equal? 1 (length (lsp:connections))))

(lsp:define-server reach (lsp-test/servers:fake-command "reach") (root '("go.mod")))

(test "with lsp:extend-to-xref?, a file outside the connection's root that M-. reaches is managed by the same connection; without it, the file gets a connection of its own root"
  (lsp:shutdown-all)
  (tables:set! lsp:language-servers "fakelang" (list reach))
  (lsp-test/servers:configure! "reach" `(capabilities ("textDocumentSync" . 2) ("definitionProvider" . #t))
    `(responses ("textDocument/definition" . #((("uri" . ,(lsp:path->uri (string-append lsp-test/servers:project "/two/x.fk")))
                                                ("range" ("start" ("line" . 0) ("character" . 4)) ("end" ("line" . 0) ("character" . 5)))))))
    '(name . "reach"))
  (buffers:with-buffer a (lsp:ensure))
  (lsp-test/servers:wait-for "reach" "textDocument/didOpen")
  (hooks:add! lsp-test/servers:fake-mode-hook lsp:ensure)
  (options:set! lsp:extend-to-xref? #t)
  (views:set-point! (lsp-test/servers:view) 5)
  (lsp-test/servers:press-until-ended! "M-." xref:find-definitions)
  (check-equal? "x.fk" (buffers:name (views:buffer (lsp-test/servers:view))))
  (lsp-test/servers:wait-for "reach" "textDocument/didOpen" 2)
  (check-equal? '(("/project/one/") ("/project/one/"))
                (list (roots) (map (lambda (c) (short (lsp:connection-root c))) (lsp:buffer-connections (views:buffer (lsp-test/servers:view))))))
  (test-user:press! "M-,")
  (buffers:kill! (files:buffer-visiting (string-append lsp-test/servers:project "/two/x.fk")))
  (options:set! lsp:extend-to-xref? #f)
  (lsp-test/servers:press-until-ended! "M-." xref:find-definitions)
  (test-runner:wait-until (lambda () (= 2 (length (lsp:connections)))))
  (check-equal? '(("/project/one/" "/project/") ("/project/"))
                (list (roots) (map (lambda (c) (short (lsp:connection-root c))) (lsp:buffer-connections (views:buffer (lsp-test/servers:view))))))
  (lsp:shutdown-all)
  (hooks:remove! lsp-test/servers:fake-mode-hook lsp:ensure))

(test "a server defined in a module is named under the module; a configuration's tables:set! on a default server's name wins over the module's entry"
  (check-equal? 'lsp-test/chez-lsp:chez-lsp lsp-test/chez-lsp:chez-lsp)
  (check (lsp:server? (tables:ref lsp:servers lsp-test/chez-lsp:chez-lsp #f)))
  (let ([ours (lsp:server '("basedpyright-langserver" "--stdio") (configuration '(("basedpyright" ("analysis" ("typeCheckingMode" . "basic"))))))])
    (tables:set! lsp:servers lsp:basedpyright ours)
    (check (eq? ours (tables:ref lsp:servers lsp:basedpyright #f)))))

(test "the plugin lists each language's servers in Eglot's order"
  (check-equal? (list lsp:gopls) (tables:ref lsp:language-servers "go" #f)))

(test "an unknown clause, capability or confirmation is a syntax error"
  (for-each
    (lambda (module message) (check-raises (syntax-error? message) (load-module! (list 'lsp-test 'bad-forms module))))
    '(clause capability confirmation)
    '("invalid clause" "not a capability" "not a confirmation")))
