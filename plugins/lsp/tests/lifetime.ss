(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (timers) (modes) (buffers) (document) (views)
        (layout) (files) (lsp) (lsp-test servers))

(options:set! lsp:send-changes-delay 0.05)

;; The claims are that nothing more is said or started, so the check
;; waits a while first.
(define (a-while) (timers:sleep 0.2))

(lsp:define-server alpha (lsp-test/servers:fake-command "alpha"))

(lsp-test/servers:configure! "alpha"
  '(capabilities ("textDocumentSync" ("openClose" . #t) ("change" . 2) ("willSave" . #t) ("willSaveWaitUntil" . #t) ("save" ("includeText" . #f))))
  '(responses ("textDocument/willSaveWaitUntil" . #((("range" ("start" ("line" . 0) ("character" . 0)) ("end" ("line" . 0) ("character" . 0))) ("newText" . "# "))))))

(tables:set! lsp:language-servers "fakelang" (list alpha))

(hooks:add! lsp-test/servers:fake-mode-hook lsp:ensure)

(define a-path (string-append lsp-test/servers:project "/a.fk"))

(define c-path (string-append lsp-test/servers:project "/c.fk"))

(lsp-test/servers:write-file! a-path "one\n")

(define a (lsp-test/servers:visit! a-path))

(lsp-test/servers:wait-for "alpha" "textDocument/didOpen")

(test "saving sends willSave, applies willSaveWaitUntil's edits, then didSave"
  (buffers:replace! a 1 1 "x")
  (files:save-buffer a)
  (lsp-test/servers:wait-for "alpha" "textDocument/didSave")
  (check-equal? '("# xone\n" ("textDocument/willSave" "textDocument/willSaveWaitUntil" "textDocument/didSave"))
                (list (lsp-test/servers:text a)
                      (filter (lambda (m) (member m '("textDocument/willSave" "textDocument/willSaveWaitUntil" "textDocument/didSave")))
                              (lsp-test/servers:methods "alpha"))))
  (check-equal? "# xone\n" (call-with-input-file a-path get-string-all)))

(test "renaming the file closes it on the server and opens it again under the new name; changing its mode or killing it closes it"
  (files:rename-file a-path c-path)
  (lsp-test/servers:wait-for "alpha" "textDocument/didOpen" 2)
  (check-equal? (list (lsp:path->uri a-path) (lsp:path->uri c-path))
                (list (lsp-test/servers:ref (lsp-test/servers:last-of "alpha" "textDocument/didClose") "params" "textDocument" "uri")
                      (lsp-test/servers:ref (lsp-test/servers:last-of "alpha" "textDocument/didOpen") "params" "textDocument" "uri")))
  (modes:set-major-mode modes:fundamental a)
  (lsp-test/servers:wait-for "alpha" "textDocument/didClose" 2)
  (check (not (lsp:managed? a)))
  (modes:set-major-mode lsp-test/servers:fake-mode a)
  (lsp-test/servers:wait-for "alpha" "textDocument/didOpen" 3)
  (check (lsp:managed? a))
  (buffers:kill! a)
  (lsp-test/servers:wait-for "alpha" "textDocument/didClose" 3)
  (check-equal? 1 (length (lsp:connections))))

(test "with lsp:autoshutdown? the connection goes when its last buffer is killed"
  (options:set! lsp:autoshutdown? #t)
  (let ([c (lsp-test/servers:visit! c-path)])
    (lsp-test/servers:wait-for "alpha" "textDocument/didOpen" 4)
    (buffers:kill! c)
    (test-runner:wait-until (lambda () (null? (lsp:connections))))
    (let ([methods (lsp-test/servers:methods "alpha")])
      (check-equal? '("textDocument/didClose" "shutdown" "exit") (list-tail methods (- (length methods) 3)))))
  (options:unset! lsp:autoshutdown?))

(define c #f)

(test "a server that ends without being asked starts again, with its buffers, when it had run lsp:autoreconnect seconds, saying so"
  (set! c (lsp-test/servers:visit! c-path))
  (test-runner:wait-until (lambda () (= 2 (length (lsp-test/servers:of-method "alpha" "initialize")))))
  (lsp-test/servers:wait-for "alpha" "textDocument/didOpen" 5)
  (options:set! lsp:autoreconnect 0)
  (lsp-test/servers:said!)
  (let ([first (car (lsp:connections))])
    (lsp:notify first "fake/crash" '())
    (test-runner:wait-until (lambda () (= 3 (length (lsp-test/servers:of-method "alpha" "initialize")))))
    (lsp-test/servers:wait-for "alpha" "textDocument/didOpen" 6)
    (check-equal? '(1 #f #t) (list (length (lsp:connections)) (eq? first (car (lsp:connections))) (lsp:managed? c))))
  (check-equal? '("fake exited with status 3" "Reconnecting after unexpected server exit." "Reconnected!") (lsp-test/servers:said!)))

(test "one that ended before running that long is not started again"
  (options:set! lsp:autoreconnect 60)
  (lsp:notify (car (lsp:connections)) "fake/crash" '())
  (test-runner:wait-until (lambda () (null? (lsp:connections))))
  (a-while)
  (check-equal? '(() ("fake exited with status 3" "Not auto-reconnecting, last one didn't last long.")) (list (lsp:connections) (lsp-test/servers:said!))))

(test "with lsp:autoreconnect #f a server that ends is not started again, and its buffers are no longer managed"
  (buffers:with-buffer c (lsp:ensure))
  (test-runner:wait-until (lambda () (= 4 (length (lsp-test/servers:of-method "alpha" "initialize")))))
  (lsp-test/servers:wait-for "alpha" "textDocument/didOpen" 7)
  (options:set! lsp:autoreconnect #f)
  (lsp:notify (car (lsp:connections)) "fake/crash" '())
  (test-runner:wait-until (lambda () (null? (lsp:connections))))
  (a-while)
  (check-equal? '(() #f ("fake exited with status 3")) (list (lsp:connections) (lsp:managed? c) (lsp-test/servers:said!)))
  (options:unset! lsp:autoreconnect))

(test "lsp:ensure in a mode hook runs again after a module loads, which starts nothing twice"
  (buffers:with-buffer c (lsp:ensure))
  (test-runner:wait-until (lambda () (= 5 (length (lsp-test/servers:of-method "alpha" "initialize")))))
  (load-module! '(lsp-test chez-lsp))
  (a-while)
  (check-equal? '(1 5) (list (length (lsp:connections)) (length (lsp-test/servers:of-method "alpha" "initialize")))))

(test "lsp:shutdown-all shuts down every connection"
  (lsp:shutdown-all)
  (check-equal? '() (lsp:connections)))
