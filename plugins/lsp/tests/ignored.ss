(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (timers) (buffers) (document) (views) (layout)
        (files) (diagnostics) (lsp) (lsp-test servers))

(options:set! lsp:send-changes-delay 0.05)

;; The claim is that no diagnostic comes, so the check waits a while
;; first.
(define (a-while) (timers:sleep 0.3))

(define (pull-response message)
  `(("kind" . "full") ("items" . #((("range" ("start" ("line" . 0) ("character" . 0)) ("end" ("line" . 0) ("character" . 3))) ("severity" . 2) ("message" . ,message))))))

(lsp-test/servers:configure! "lint"
  `(capabilities ("textDocumentSync" . 2) ("diagnosticProvider" ("interFileDependencies" . #f) ("workspaceDiagnostics" . #f)))
  `(responses ("textDocument/diagnostic" . ,(pull-response "pulled")))
  '(name . "lint"))

(lsp:define-server lint (lsp-test/servers:fake-command "lint") (ignored-capabilities (lsp:capabilities diagnostics)))

(tables:set! lsp:language-servers "fakelang" (list lint))

(hooks:add! lsp-test/servers:fake-mode-hook lsp:ensure)

(define a-path (string-append lsp-test/servers:project "/a.fk"))

(define (push! path message)
  (lsp-test/servers:publish! (car (lsp:connections)) path
    (list `(("range" ("start" ("line" . 1) ("character" . 0)) ("end" ("line" . 1) ("character" . 3))) ("severity" . 1) ("message" . ,message)))))

(define (messages b) (map diagnostics:diagnostic-message (diagnostics:in b)))

(lsp-test/servers:write-file! a-path "one\ntwo\n")

(define a (lsp-test/servers:visit! a-path))

(lsp-test/servers:wait-for "lint" "textDocument/didOpen")

(test "a server that ignores diagnostics gives none: neither pulled nor pushed"
  (push! a-path "pushed")
  (buffers:replace! a 1 1 "x")
  (lsp-test/servers:wait-for "lint" "textDocument/didChange")
  (a-while)
  (check-equal? '(() 0 ()) (list (diagnostics:in a) (length (lsp-test/servers:of-method "lint" "textDocument/diagnostic")) (diagnostics:under lsp-test/servers:project))))

(lsp:define-server lint (lsp-test/servers:fake-command "lint"))

(define b-path (string-append lsp-test/servers:project "/b.fk"))

(define c-path (string-append lsp-test/servers:project "/c.fk"))

(define b #f)

(define c #f)

(test "set locally, lsp:ignored-capabilities does the same in one buffer alone"
  (lsp-test/servers:write-file! b-path "three\n")
  (lsp-test/servers:write-file! c-path "four\n")
  (buffers:with-buffer a (options:set-local! lsp:ignored-capabilities (lsp:capabilities diagnostics)))
  (lsp:reconnect (car (lsp:connections)))
  (set! b (lsp-test/servers:visit! b-path))
  (set! c (lsp-test/servers:visit! c-path))
  (test-runner:wait-until (lambda () (= 2 (length (lsp-test/servers:of-method "lint" "textDocument/diagnostic")))))
  (push! a-path "pushed")
  (push! b-path "pushed")
  (test-runner:wait-until (lambda () (equal? '("pushed") (messages b))))
  (test-runner:wait-until (lambda () (equal? '("pulled") (messages c))))
  (check-equal? '() (messages a)))

(test "a change sent asks again for every open document of the server, the changed one first"
  (buffers:replace! b 1 1 "x")
  (test-runner:wait-until (lambda () (= 4 (length (lsp-test/servers:of-method "lint" "textDocument/diagnostic")))))
  (check-equal? (map lsp:path->uri (list b-path c-path b-path c-path))
                (map (lambda (m) (lsp-test/servers:ref m "params" "textDocument" "uri")) (lsp-test/servers:of-method "lint" "textDocument/diagnostic"))))
