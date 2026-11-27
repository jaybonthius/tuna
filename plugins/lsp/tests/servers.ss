(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (keys) (modes) (auto-mode) (buffers) (document)
        (views) (layout) (files) (projects) (lsp) (lsp-test servers))

(options:set! lsp:send-changes-delay 0.05)

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

(define (in-view thunk) (views:call-with-view (lsp-test/servers:view) thunk))

(define (short root) (substring root (string-length lsp-test/servers:home) (string-length root)))

(lsp:define-server missing '("no-such-language-server"))

(lsp:define-server alpha (lsp-test/servers:fake-command "alpha"))

(lsp-test/servers:configure! "alpha" '(capabilities ("textDocumentSync" . 2)))

(hooks:add! lsp-test/servers:fake-mode-hook lsp:ensure)

(define a #f)

(test "a list of names gives the first whose program is found, and the buffer is managed, the state mode on"
  (tables:set! lsp:language-servers "fakelang" (list (list missing alpha)))
  (lsp-test/servers:write-file! (string-append lsp-test/servers:project "/a.fk") "one\n")
  (set! a (lsp-test/servers:visit! (string-append lsp-test/servers:project "/a.fk")))
  (lsp-test/servers:wait-for "alpha" "textDocument/didOpen")
  (check-equal? (list alpha) (map lsp:connection-server (lsp:buffer-connections a)))
  (check (lsp:managed? a))
  (check (modes:on? lsp:managed? (lsp-test/servers:view))))

(test "a server none of whose programs is found is reported once per buffer, though the mode's hooks run again after each module loads"
  (tables:set! lsp:language-servers "fakelang" (list alpha missing))
  (lsp-test/servers:said!)
  (buffers:with-buffer a (lsp:ensure))
  (buffers:with-buffer a (lsp:ensure))
  (check-equal? (list (format "lsp: no server of (~a) is installed" missing)) (lsp-test/servers:said!)))

(test "a mode with no language gets no server, which lsp:ensure reports once"
  (lsp-test/servers:write-file! (string-append lsp-test/servers:project "/plain.txt") "x\n")
  (let ([plain (lsp-test/servers:visit! (string-append lsp-test/servers:project "/plain.txt"))])
    (buffers:with-buffer plain (lsp:ensure))
    (buffers:with-buffer plain (lsp:ensure))
    (check-equal? '("lsp: modes:fundamental has no language") (lsp-test/servers:said!))))

(tables:define-table other-keymap)

(hooks:define-hook other-hook)

(modes:define-major-mode other-mode (keymap other-keymap) (hook other-hook) (language "otherlang"))

(tables:set! auto-mode:file-names "ot" other-mode)

(hooks:add! other-hook lsp:ensure)

(define b #f)

(test "two languages that list one name share its connection, each document sent with its own language"
  (tables:set! lsp:language-servers "otherlang" (list alpha))
  (lsp-test/servers:write-file! (string-append lsp-test/servers:project "/b.ot") "two\n")
  (set! b (lsp-test/servers:visit! (string-append lsp-test/servers:project "/b.ot")))
  (lsp-test/servers:wait-for "alpha" "textDocument/didOpen" 2)
  (check-equal? '(1 #t) (list (length (lsp:connections)) (eq? (car (lsp:buffer-connections a)) (car (lsp:buffer-connections b)))))
  (check-equal? "otherlang" (lsp-test/servers:ref (cadr (lsp-test/servers:of-method "alpha" "textDocument/didOpen")) "params" "textDocument" "languageId")))

(define first-connection (car (lsp:connections)))

(lsp:define-server alpha (lsp-test/servers:fake-command "alpha") (initialization-options '(("again" . #t))))

(test "the description defined again starts no second server and keeps the buffers managed"
  (buffers:with-buffer a (lsp:ensure))
  (check-equal? '(1 #t #t #t) (list (length (lsp:connections)) (eq? (car (lsp:connections)) first-connection) (lsp:managed? a) (lsp:managed? b))))

(test "lsp:reconnect starts the server again with its description now, for the same buffers, saying so with the name the status line shows"
  (lsp-test/servers:said!)
  (lsp:reconnect first-connection)
  (test-runner:wait-until (lambda () (= 2 (length (lsp-test/servers:of-method "alpha" "initialize")))))
  (check-equal? '(("again" . #t)) (lsp-test/servers:ref (cadr (lsp-test/servers:of-method "alpha" "initialize")) "params" "initializationOptions"))
  (test-runner:wait-until (lambda () (= 4 (length (lsp-test/servers:of-method "alpha" "textDocument/didOpen")))))
  (check-equal? '(1 #t #t #f) (list (length (lsp:connections)) (lsp:managed? a) (lsp:managed? b) (eq? (car (lsp:connections)) first-connection)))
  (check-equal? '("Asking fake politely to terminate" "fake exited with status 0" "Reconnected!") (lsp-test/servers:said!)))

(test "a name removed from a language's list releases its buffers at their next lsp:ensure, closing them on the server"
  (tables:set! lsp:language-servers "otherlang" '())
  (buffers:with-buffer b (lsp:ensure))
  (check-equal? '(#f #t) (list (lsp:managed? b) (lsp:managed? a)))
  (lsp-test/servers:wait-for "alpha" "textDocument/didClose")
  (check-equal? (lsp:path->uri (string-append lsp-test/servers:project "/b.ot"))
                (lsp-test/servers:ref (lsp-test/servers:last-of "alpha" "textDocument/didClose") "params" "textDocument" "uri")))

(lsp:define-server modules (lsp-test/servers:fake-command "modules") (root '("go.mod")))

(lsp:define-server rooted (lsp-test/servers:fake-command "rooted") (root (lambda (folder) (string-append folder "../"))))

(test "a root clause of file names gives each module its own connection, while projects:find still gives the repository; a procedure's root is its answer"
  (lsp-test/servers:configure! "modules" '(capabilities ("textDocumentSync" . 2)))
  (tables:set! lsp:language-servers "otherlang" (list modules))
  (lsp-test/servers:write-file! (string-append lsp-test/servers:project "/one/go.mod") "")
  (lsp-test/servers:write-file! (string-append lsp-test/servers:project "/two/go.mod") "")
  (let ([m1 (lsp-test/servers:visit! (string-append lsp-test/servers:project "/one/x.ot"))] [m2 (lsp-test/servers:visit! (string-append lsp-test/servers:project "/two/y.ot"))])
    (lsp-test/servers:wait-for "modules" "textDocument/didOpen" 2)
    (check-equal? '("/project/one/" "/project/two/") (map (lambda (b) (short (lsp:connection-root (car (lsp:buffer-connections b))))) (list m1 m2)))
    (check-equal? "/project/" (short (projects:root (projects:find (string-append lsp-test/servers:project "/one"))))))
  (lsp-test/servers:configure! "rooted" '(capabilities ("textDocumentSync" . 2)))
  (tables:set! lsp:language-servers "otherlang" (list rooted))
  (let ([m3 (lsp-test/servers:visit! (string-append lsp-test/servers:project "/one/z.ot"))])
    (lsp-test/servers:wait-for "rooted" "textDocument/didOpen")
    (check-equal? "/project/one/../" (short (lsp:connection-root (car (lsp:buffer-connections m3)))))))

(define folders '())

(lsp:define-server types (lsp-test/servers:fake-command "types") (initialization-options '(("who" . "types")))
  (configuration (lambda (folder) (set! folders (cons folder folders)) '(("types" ("strict" . #t))))))

(lsp:define-server style (lsp-test/servers:fake-command "style") (initialization-options '(("who" . "style")))
  (configuration '(("style" ("lineLength" . 88)))) (ignored-capabilities (lsp:capabilities rename)))

(define both #f)

(define (connection-of name) (find (lambda (c) (eq? (lsp:connection-server c) name)) (lsp:buffer-connections both)))

(define (ask-configuration! c id section scope)
  (lsp-test/servers:send! c `(("jsonrpc" . "2.0") ("id" . ,id) ("method" . "workspace/configuration")
                     ("params" ("items" . #((("section" . ,section) ("scopeUri" . ,(lsp:path->uri scope)))))))))

(test "two servers for one buffer: each is sent its own initialization options and configuration, and asked for its configuration answers by section; a procedure is called with the folder a request names"
  (lsp-test/servers:configure! "types" '(capabilities ("textDocumentSync" . 2) ("documentFormattingProvider" . #t) ("renameProvider" . #t)))
  (lsp-test/servers:configure! "style" '(capabilities ("textDocumentSync" . 2) ("documentFormattingProvider" . #t) ("renameProvider" . #t)))
  (tables:set! lsp:language-servers "otherlang" (list types style))
  (set! both (lsp-test/servers:visit! (string-append lsp-test/servers:project "/both.ot")))
  (lsp-test/servers:wait-for "types" "textDocument/didOpen")
  (lsp-test/servers:wait-for "style" "textDocument/didOpen")
  (check-equal? '("types" "style") (map (lambda (n) (lsp-test/servers:ref (lsp-test/servers:last-of n "initialize") "params" "initializationOptions" "who")) '("types" "style")))
  (check-equal? '((("types" ("strict" . #t))) (("style" ("lineLength" . 88))))
                (map (lambda (n) (lsp-test/servers:ref (lsp-test/servers:last-of n "workspace/didChangeConfiguration") "params" "settings")) '("types" "style")))
  (ask-configuration! (connection-of types) "q1" "types.strict" (string-append lsp-test/servers:project "/sub/"))
  (ask-configuration! (connection-of style) "q2" "style" (string-append lsp-test/servers:project "/"))
  (test-runner:wait-until (lambda () (and (lsp-test/servers:answered "types" "q1") (lsp-test/servers:answered "style" "q2"))))
  (check-equal? '(#(#t) #((("lineLength" . 88))))
                (list (lsp-test/servers:ref (lsp-test/servers:answered "types" "q1") "result") (lsp-test/servers:ref (lsp-test/servers:answered "style" "q2") "result")))
  (check-equal? "/project/sub/" (short (car folders))))

(test "lsp:send-configuration sends the configuration as lsp:servers describes it now"
  (let ([sent (length (lsp-test/servers:of-method "style" "workspace/didChangeConfiguration"))])
    (lsp:send-configuration (connection-of style))
    (lsp-test/servers:wait-for "style" "workspace/didChangeConfiguration" (+ sent 1))
    (check-equal? '(("style" ("lineLength" . 88))) (lsp-test/servers:ref (lsp-test/servers:last-of "style" "workspace/didChangeConfiguration") "params" "settings"))))

(lsp:define-server types (lsp-test/servers:fake-command "types") (initialization-options '(("who" . "types")))
  (ignored-capabilities (lsp:capabilities formatting)))

(test "ignoring a capability on one server moves it to the next: formatting goes to the second when the first ignores it, and rename stays with the first, which keeps it"
  (lsp:reconnect (connection-of types))
  (test-runner:wait-until (lambda () (= 2 (length (lsp-test/servers:of-method "types" "textDocument/didOpen")))))
  (lsp-test/servers:configure! "style" '(capabilities ("textDocumentSync" . 2) ("documentFormattingProvider" . #t) ("renameProvider" . #t))
    '(responses ("textDocument/formatting" . #((("range" ("start" ("line" . 0) ("character" . 0)) ("end" ("line" . 0) ("character" . 0))) ("newText" . "# "))))))
  (in-view (lambda () (lsp:format-buffer both)))
  (check-equal? '("# " 0 1)
                (list (lsp-test/servers:text both) (length (lsp-test/servers:of-method "types" "textDocument/formatting")) (length (lsp-test/servers:of-method "style" "textDocument/formatting"))))
  (lsp-test/servers:configure! "types" '(capabilities ("textDocumentSync" . 2) ("renameProvider" . #t)) '(responses ("textDocument/rename" . null)))
  (in-view (lambda () (lsp:rename "renamed")))
  (check-equal? '(1 0) (list (length (lsp-test/servers:of-method "types" "textDocument/rename")) (length (lsp-test/servers:of-method "style" "textDocument/rename")))))

(test "lsp:ignored-capabilities, set locally, removes a feature in one buffer"
  (buffers:with-buffer both (options:set-local! lsp:ignored-capabilities (lsp:capabilities formatting)))
  (check-raises (raised? 'lsp:format-buffer "No server formats here") (in-view (lambda () (lsp:format-buffer both)))))

(test "initialize offers all the plugin can do, a feature a server ignores included, as Eglot's does"
  (check-equal? '((#t #t) (#t #t))
                (map (lambda (n) (list (and (lsp-test/servers:ref (lsp-test/servers:last-of n "initialize") "params" "capabilities" "textDocument" "rename") #t)
                                       (and (lsp-test/servers:ref (lsp-test/servers:last-of n "initialize") "params" "capabilities" "textDocument" "formatting") #t)))
                     '("types" "style"))))
