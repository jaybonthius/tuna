(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (keys) (buffers) (document) (views) (layout)
        (files) (xref) (completion) (completion-list) (status-line) (lsp) (servers))

(options:set! lsp:send-changes-delay 0.05)

(keys:bind! keys:global "C-c e" lsp:show-events)

(keys:bind! keys:global "C-c k" lsp:shutdown)

(lsp:define-server types (servers:fake-command "types"))

(lsp:define-server style (servers:fake-command "style"))

(define a-path (string-append servers:project "/a.fk"))

(define (location character)
  `(("uri" . ,(lsp:path->uri a-path)) ("range" ("start" ("line" . 0) ("character" . ,character)) ("end" ("line" . 0) ("character" . ,(+ character 1))))))

(servers:write-file! a-path "total(1)\n")

(servers:configure! "types"
  '(capabilities ("textDocumentSync" . 2) ("declarationProvider" . #t) ("implementationProvider" . #t) ("typeDefinitionProvider" . #t))
  `(responses ("textDocument/declaration" . ,(vector (location 6)))
              ("textDocument/implementation" . ,(vector (location 1)))
              ("textDocument/typeDefinition" . ,(vector (location 2))))
  '(name . "types"))

(servers:configure! "style" '(capabilities ("textDocumentSync" . 2)) '(name . "style"))

(tables:set! lsp:language-servers "fakelang" (list types style))

(hooks:add! servers:fake-mode-hook lsp:ensure)

(define a (servers:visit! a-path))

(servers:wait-for "types" "textDocument/didOpen")

(servers:wait-for "style" "textDocument/didOpen")

(define (status)
  (test-user:settle)
  (let ([shown (test-user:elements (test-user:screen) "lsp-status")])
    (and (pair? shown) (test-user:element-text (car shown)))))

(define (status-segment)
  (find (lambda (e) (equal? "lsp:status" (test-user:element-attribute e "data-segment")))
        (test-user:elements-with (test-user:screen) "data-segment")))

(define (choices)
  (let ([s (views:call-with-view (servers:view) completion:current-session)])
    (test-runner:wait-until (lambda () (not (completion:session-busy? s))))
    (let ([ms (completion:session-matches s)])
      (map (lambda (k) (completion:text s (completion:matches-ref ms k))) (iota (completion:matches-count ms))))))

(define (jsonrpc-events name)
  (let* ([prefix (string-append "*" name " events*")] [n (string-length prefix)])
    (car (last-pair (filter (lambda (b) (let ([s (buffers:name b)]) (and (>= (string-length s) n) (string=? prefix (substring s 0 n)))))
                            (buffers:all))))))

(define (lines s)
  (let loop ([i 0] [start 0] [acc '()])
    (cond
      [(= i (string-length s)) (reverse (if (< start i) (cons (substring s start i) acc) acc))]
      [(char=? (string-ref s i) #\newline) (loop (+ i 1) (+ i 1) (cons (substring s start i) acc))]
      [else (loop (+ i 1) start acc)])))

(test "the status line names each server of the buffer, with its work in progress while lsp:report-progress? holds"
  (check-equal? "types style " (status))
  (servers:send! (car (lsp:buffer-connections a))
    '(("jsonrpc" . "2.0") ("method" . "$/progress")
      ("params" ("token" . "t") ("value" ("kind" . "begin") ("title" . "Indexing") ("percentage" . 10)))))
  (test-runner:wait-until (lambda () (equal? "types Indexing 10% style " (status))))
  (options:set! lsp:report-progress? #f)
  (check-equal? "types style " (status))
  (options:unset! lsp:report-progress?))

(test "the segment is placed in the status line"
  (check (status-line:place? (tables:ref status-line:segments lsp:status #f))))

(test "initialize carries Tuna's process id, or null with lsp:send-process-id? off"
  (check (integer? (servers:ref (servers:last-of "types" "initialize") "params" "processId")))
  (options:set! lsp:send-process-id? #f)
  (lsp:reconnect (cadr (lsp:buffer-connections a)))
  (test-runner:wait-until (lambda () (= 2 (length (servers:of-method "style" "initialize")))))
  (check-equal? 'null (servers:ref (servers:last-of "style" "initialize") "params" "processId"))
  (options:unset! lsp:send-process-id?)
  (servers:wait-for "style" "textDocument/didOpen" 2))

(test "the declaration, implementation and type definition go as M-. does"
  (check-equal? '(7 2 3)
                (map (lambda (command)
                       (views:set-point! (servers:view) 1)
                       (views:call-with-view (servers:view) command)
                       (views:point (servers:view)))
                     (list lsp:find-declaration lsp:find-implementation lsp:find-type-definition))))

(test "in a managed buffer M-? asks no identifier, as Eglot's buffers do"
  (check-equal? #f (buffers:with-buffer a (xref:prompt-for-identifier))))

(test "with several connections, a command that acts on one asks which, by the names the status line shows"
  (test-user:press! "C-c e")
  (check-equal? '("types" "style") (choices))
  (servers:press-until-ended! "C-n RET" lsp:show-events)
  (check (pair? (views:showing (jsonrpc-events (symbol->string style)))))
  (test-user:press! "C-c k")
  (check-equal? "Connection: " (servers:question))
  (check-equal? '(cancelled) (servers:reports-during (lambda () (test-user:press! "C-g")))))

(test "what a server writes to its standard error goes to its events log"
  (lsp:notify (car (lsp:buffer-connections a)) "fake/stderr" '(("line" . "warming up")))
  (test-runner:wait-until
    (lambda () (member "stderr: warming up" (lines (servers:text (jsonrpc-events (symbol->string types))))))))

(test "a click on the status shows the first connection's events log"
  (layout:switch-to-buffer a)
  (for-each (lambda (v) (unless (eq? v (servers:view)) (when (eq? (views:buffer v) (jsonrpc-events (symbol->string style))) (views:set-buffer! v a))))
            (layout:views))
  (test-user:settle)
  (test-user:click-element! (status-segment))
  (check (pair? (views:showing (jsonrpc-events (symbol->string types))))))

(lsp:define-server mute '("sleep" "30"))

(test "a server that does not answer initialize within lsp:connect-timeout is stopped, and its events log outlives it"
  (tables:set! lsp:language-servers "fakelang" (list mute))
  (options:set! lsp:connect-timeout 0.3)
  (servers:write-file! (string-append servers:project "/b.fk") "x\n")
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (let ([b (servers:visit! (string-append servers:project "/b.fk"))])
      (test-runner:wait-until (lambda () (pair? reported)))
      (advice-remove! report keep)
      (check-equal? (list (format "~a gave no answer to initialize in 0.3 s" mute)) (map condition-message reported))
      (test-runner:wait-until (lambda () (null? (lsp:buffer-connections b))))))
  (check (buffers:live? (jsonrpc-events (symbol->string mute))))
  (options:unset! lsp:connect-timeout))
