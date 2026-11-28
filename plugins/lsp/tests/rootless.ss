(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (languages) (modes) (buffers) (views) (layout) (files)
        (lsp) (lsp-test servers))

(options:set! lsp:send-changes-delay 0.05)

(define home lsp-test/servers:home)

(define commanded '())

(define configured '())

(define initialized '())

(lsp:define-server alpha
  (lambda (root) (set! commanded (cons root commanded)) (lsp-test/servers:fake-command "alpha"))
  (initialization-options (lambda (root) (set! initialized (cons root initialized)) '()))
  (configuration (lambda (folder) (set! configured (cons folder configured)) '(("alpha" ("on" . #t))))))

(lsp-test/servers:configure! "alpha" '(capabilities ("textDocumentSync" . 2)) '(name . "alpha"))

(tables:set! lsp:language-servers "fakelang" (list alpha))

(hooks:add! lsp-test/servers:fake-mode-hook lsp:ensure)

(define loose (string-append home "/loose/a.fk"))

(define other (string-append home "/other/deeper/b.fk"))

(lsp-test/servers:write-file! loose "one\n")
(lsp-test/servers:write-file! other "two\n")

(define (initialize) (lsp-test/servers:ref (lsp-test/servers:last-of "alpha" "initialize") "params"))

(define (directory c) (lsp:request c "fake/directory" 'null))

(test "a file in no project gets a connection with no root: initialize carries rootPath, rootUri and workspaceFolders null, and the command, initialization-options and configuration procedures get #f"
  (let ([a (lsp-test/servers:visit! loose)])
    (lsp-test/servers:wait-for "alpha" "textDocument/didOpen")
    (check-equal? '(null null null)
                  (map (lambda (key) (lsp-test/servers:ref (initialize) key)) '("rootPath" "rootUri" "workspaceFolders")))
    (check-equal? '(#f) (map lsp:connection-root (lsp:buffer-connections a)))
    (check-equal? '((#f) (#f) (#f)) (list commanded initialized configured))))

(test "the server of a file in no project runs in that file's folder"
  (check-equal? (string-append home "/loose") (directory (car (lsp:connections)))))

(test "a second file in no project, in another folder, joins the same connection"
  (let ([b (lsp-test/servers:visit! other)])
    (lsp-test/servers:wait-for "alpha" "textDocument/didOpen" 2)
    (check-equal? 1 (length (lsp:connections)))
    (check (eq? (car (lsp:connections)) (car (lsp:buffer-connections b))))))

(test "asked for its workspace folders, a connection with no root answers null; asked for its configuration with no scope, the procedure gets #f"
  (let ([c (car (lsp:connections))])
    (set! configured '())
    (lsp-test/servers:send! c '(("jsonrpc" . "2.0") ("id" . "w1") ("method" . "workspace/workspaceFolders")))
    (lsp-test/servers:send! c '(("jsonrpc" . "2.0") ("id" . "c1") ("method" . "workspace/configuration")
                               ("params" ("items" . #((("section" . "alpha")))))))
    (test-runner:wait-until (lambda () (and (lsp-test/servers:answered "alpha" "w1") (lsp-test/servers:answered "alpha" "c1"))))
    (check-equal? '(null #((("on" . #t))))
                  (list (lsp-test/servers:ref (lsp-test/servers:answered "alpha" "w1") "result")
                        (lsp-test/servers:ref (lsp-test/servers:answered "alpha" "c1") "result")))
    (check-equal? '(#f) configured)))

(test "lsp:reconnect starts a connection with no root again with no root, in the folder it ran in, for the same buffers"
  (lsp:reconnect (car (lsp:connections)))
  (lsp-test/servers:wait-for "alpha" "initialize" 2)
  (lsp-test/servers:wait-for "alpha" "textDocument/didOpen" 4)
  (let ([c (car (lsp:connections))])
    (check-equal? '(1 #f null) (list (length (lsp:connections)) (lsp:connection-root c) (lsp-test/servers:ref (initialize) "rootUri")))
    (check-equal? (string-append home "/loose") (directory c))))

(test "a connection with no root that ends unasked starts again with no root, in the folder it ran in"
  (options:set! lsp:autoreconnect 0)
  (lsp:notify (car (lsp:connections)) "fake/crash" '())
  (lsp-test/servers:wait-for "alpha" "initialize" 3)
  (lsp-test/servers:wait-for "alpha" "textDocument/didOpen" 6)
  (let ([c (car (lsp:connections))])
    (check-equal? '(1 #f null) (list (length (lsp:connections)) (lsp:connection-root c) (lsp-test/servers:ref (initialize) "rootUri")))
    (check-equal? (string-append home "/loose") (directory c)))
  (options:unset! lsp:autoreconnect))

(test "a file in a project still gets the project's root, beside the connection with none"
  (let ([p (lsp-test/servers:visit! (string-append lsp-test/servers:project "/p.fk"))])
    (lsp-test/servers:wait-for "alpha" "initialize" 4)
    (check-equal? (list (string-append lsp-test/servers:project "/")) (map lsp:connection-root (lsp:buffer-connections p)))
    (check-equal? 2 (length (lsp:connections)))))

(tables:define-table sml-keymap)

(hooks:define-hook sml-hook)

(modes:define-major-mode sml-mode (keymap sml-keymap) (hook sml-hook))

(languages:define-language "sml" (mode sml-mode))

(define bin (string-append home "/bin"))

;; millet-ls is not Tuna's to ship, so a script of that name on the PATH
;; runs the fake server in its place, whatever its arguments.
(lsp-test/servers:write-file! (string-append bin "/millet-ls")
  (apply string-append "#!/bin/sh\nexec"
         (map (lambda (word) (string-append " '" word "'")) (lsp-test/servers:fake-command "millet"))))
(chmod (string-append bin "/millet-ls") #o755)
(putenv "PATH" (string-append bin ":" (getenv "PATH")))
(lsp-test/servers:configure! "millet" '(capabilities ("textDocumentSync" . 2)))

(test "millet is started with no root argument for a file in no project, and with its root in a project"
  (let ([s (files:visit (string-append home "/loose/c.sml"))] [t (files:visit (string-append lsp-test/servers:project "/d.sml"))])
    (modes:set-major-mode sml-mode s)
    (modes:set-major-mode sml-mode t)
    (buffers:with-buffer s (lsp:ensure-now))
    (buffers:with-buffer t (lsp:ensure-now))
    (lsp-test/servers:wait-for "millet" "textDocument/didOpen" 2)
    (check-equal? (list '("millet-ls") (list "millet-ls" (string-append lsp-test/servers:project "/")))
                  (map (lambda (b) (lsp:connection-command (car (lsp:buffer-connections b)))) (list s t)))))

(test "lsp:shutdown-all shuts down every connection"
  (lsp:shutdown-all)
  (check-equal? '() (lsp:connections)))
