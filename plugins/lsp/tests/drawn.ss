(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (timers) (modes) (buffers) (views) (layout)
        (files) (minibuffer) (lsp) (lsp-test servers))

(options:set! lsp:send-changes-delay 0.05)

;; The claims are that nothing is started or said, so the check waits a
;; while first.
(define (a-while) (test-user:settle) (timers:sleep 0.2) (test-user:settle))

(lsp:define-server alpha (lsp-test/servers:fake-command "alpha"))

(lsp:define-server beta (lsp-test/servers:fake-command "beta"))

(lsp-test/servers:configure! "alpha" '(capabilities ("textDocumentSync" . 2)))

(lsp-test/servers:configure! "beta" '(capabilities ("textDocumentSync" . 2)))

(tables:set! lsp:language-servers "fakelang" (list alpha))

(hooks:add! lsp-test/servers:fake-mode-hook lsp:ensure)

(define (path name) (string-append lsp-test/servers:project "/" name))

(for-each (lambda (name) (lsp-test/servers:write-file! (path name) "one\n")) '("a.fk" "b.fk" "c.fk" "d.fk" "e.fk" "f.fk"))

(define a (files:visit (path "a.fk")))

(test "a buffer whose mode hook calls lsp:ensure starts no server while no view draws it"
  (a-while)
  (check-equal? '(() #f) (list (lsp:connections) (lsp:managed? a))))

(test "a view switched to the buffer starts its server"
  (layout:switch-to-buffer a)
  (lsp-test/servers:wait-for "alpha" "textDocument/didOpen")
  (check (lsp:managed? a)))

(test "lsp:ensure in a buffer a view draws manages it at once"
  (tables:set! lsp:language-servers "fakelang" (list alpha beta))
  (buffers:with-buffer a (lsp:ensure))
  (check-equal? (list alpha beta) (map lsp:connection-server (lsp:buffer-connections a)))
  (tables:set! lsp:language-servers "fakelang" (list alpha))
  (buffers:with-buffer a (lsp:ensure))
  (check-equal? (list alpha) (map lsp:connection-server (lsp:buffer-connections a))))

(test "a buffer whose mode changes before a view draws it is not managed when drawn, and nothing is said"
  (let ([c (files:visit (path "c.fk"))])
    (modes:set-major-mode modes:fundamental c)
    (lsp-test/servers:said!)
    (layout:switch-to-buffer c)
    (a-while)
    (check-equal? '(#f ()) (list (lsp:managed? c) (lsp-test/servers:said!)))))

(test "a view that stops showing a buffer does not start the buffer's servers"
  (let ([d (files:visit (path "d.fk"))])
    (modes:set-major-mode modes:fundamental d)
    (layout:switch-to-buffer d)
    (test-user:settle)
    (layout:switch-to-buffer a)
    (modes:set-major-mode lsp-test/servers:fake-mode d)
    (a-while)
    (check (not (lsp:managed? d)))))

(test "lsp:ensure-now manages a buffer no view draws at once, and asks nothing when the buffer has connections"
  (let ([e (files:visit (path "e.fk"))])
    (buffers:with-buffer e (lsp:ensure-now))
    (check (lsp:managed? e))
    (buffers:with-buffer e (lsp:ensure-now))
    (test-user:settle)
    (check-equal? '(#f #t) (list (minibuffer:current-prompt) (lsp:managed? e)))))

(test "lsp:start manages a buffer no view draws at once"
  (let ([f (files:visit (path "f.fk"))])
    (check (not (lsp:managed? f)))
    (buffers:with-buffer f (lsp:start))
    (check (lsp:managed? f))))

(test "lsp:shutdown-all shuts down every connection"
  (lsp:shutdown-all)
  (check-equal? '() (lsp:connections)))
