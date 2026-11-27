(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (timers) (tables) (buffers) (document) (views) (layout)
        (files) (diagnostics) (lsp) (servers))

(options:set! lsp:send-changes-delay 0.05)

(lsp:define-server alpha (servers:fake-command "alpha"))

(servers:configure! "alpha" '(capabilities ("textDocumentSync" . 2) ("hoverProvider" . #t)))

(tables:set! lsp:language-servers "fakelang" (list alpha))

(hooks:add! servers:fake-mode-hook lsp:ensure)

(define a-path (string-append servers:project "/a.fk"))

(define (changes name)
  (map (lambda (m) (list (servers:ref m "params" "textDocument" "version") (servers:ref m "params" "contentChanges")))
       (servers:of-method name "textDocument/didChange")))

(servers:write-file! a-path "one\ntwo\n")

(define a (servers:visit! a-path))

(define c #f)

(test "a server defined by name and listed for a language is started by lsp:ensure in the mode's hook, and sent the buffer's text"
  (check (lsp:server? (tables:ref lsp:servers alpha #f)))
  (servers:wait-for "alpha" "textDocument/didOpen")
  (set! c (car (lsp:buffer-connections a)))
  (check-equal? '("initialize" "initialized" "workspace/didChangeConfiguration" "textDocument/didOpen") (servers:methods "alpha"))
  (check-equal? `(("uri" . ,(lsp:path->uri a-path)) ("languageId" . "fakelang") ("version" . 0) ("text" . "one\ntwo\n"))
                (servers:ref (servers:last-of "alpha" "textDocument/didOpen") "params" "textDocument")))

(test "each edit goes after the delay as a range of the content before it and the inserted text, with the buffer's version as the document's"
  (buffers:replace! a 4 4 "X")
  (check-equal? '("initialize" "initialized" "workspace/didChangeConfiguration" "textDocument/didOpen") (servers:methods "alpha"))
  (servers:wait-for "alpha" "textDocument/didChange")
  (check-equal? '((1 #((("range" ("start" ("line" . 0) ("character" . 3)) ("end" ("line" . 0) ("character" . 3))) ("text" . "X")))))
                (changes "alpha"))
  (check-equal? 1 (buffers:version a)))

(test "a deletion across lines counts its end from the removed text"
  (check-equal? "oneX\ntwo\n" (servers:text a))
  (buffers:replace! a 3 8 "")
  (servers:wait-for "alpha" "textDocument/didChange" 2)
  (check-equal? '(2 #((("range" ("start" ("line" . 0) ("character" . 2)) ("end" ("line" . 1) ("character" . 2))) ("text" . ""))))
                (cadr (changes "alpha"))))

(test "silent edits are sent too, and the pending edits go before any request"
  (buffers:with-silent-edits a (buffers:replace! a 1 1 "S"))
  (check-equal? 'null (lsp:request c "textDocument/hover" '(("position" ("line" . 0) ("character" . 0)))))
  (let ([methods (servers:methods "alpha")])
    (check-equal? (list 3 3 '("textDocument/didChange" "textDocument/hover"))
                  (list (length (changes "alpha")) (car (list-ref (changes "alpha") 2)) (list-tail methods (- (length methods) 2))))))

(define (encoding-server! name encoding)
  (servers:configure! name `(capabilities ("textDocumentSync" . 2) ("positionEncoding" . ,encoding))))

(lsp:define-server sixteen (servers:fake-command "sixteen"))
(lsp:define-server eight (servers:fake-command "eight"))
(lsp:define-server thirtytwo (servers:fake-command "thirtytwo"))

(test "characters are counted in the unit the server chose: a character above U+FFFF is two UTF-16 units, four UTF-8 bytes and one UTF-32 character"
  (encoding-server! "sixteen" "utf-16")
  (encoding-server! "eight" "utf-8")
  (encoding-server! "thirtytwo" "utf-32")
  (tables:set! lsp:language-servers "fakelang" (list sixteen eight thirtytwo))
  (servers:write-file! (string-append servers:project "/wide.fk") "a\x1F600;b\n")
  (let ([wide (servers:visit! (string-append servers:project "/wide.fk"))] [names '("sixteen" "eight" "thirtytwo")])
    (for-each (lambda (n) (servers:wait-for n "textDocument/didOpen")) names)
    (buffers:replace! wide 3 4 "c")
    (for-each (lambda (n) (servers:wait-for n "textDocument/didChange")) names)
    (check-equal? '((("start" ("line" . 0) ("character" . 3)) ("end" ("line" . 0) ("character" . 4)))
                    (("start" ("line" . 0) ("character" . 5)) ("end" ("line" . 0) ("character" . 6)))
                    (("start" ("line" . 0) ("character" . 2)) ("end" ("line" . 0) ("character" . 3))))
                  (map (lambda (n) (servers:ref (cadr (car (changes n))) 0 "range")) names))
    (buffers:replace! wide 2 3 "")
    (for-each (lambda (n) (servers:wait-for n "textDocument/didChange" 2)) names)
    (check-equal? '((("line" . 0) ("character" . 3)) (("line" . 0) ("character" . 5)) (("line" . 0) ("character" . 2)))
                  (map (lambda (n) (servers:ref (cadr (cadr (changes n))) 0 "range" "end")) names))))

(test "a byte that is not UTF-8 goes as U+FFFD, and an edit after it counts it as that character's three bytes in a UTF-8 server"
  (let ([raw-path (string-append servers:project "/raw.fk")])
    (call-with-port (open-file-output-port raw-path (file-options no-fail)) (lambda (p) (put-bytevector p (bytevector 97 255 98 10))))
    (let ([raw (servers:visit! raw-path)])
      (test-runner:wait-until (lambda () (= 2 (length (servers:of-method "eight" "textDocument/didOpen")))))
      (check-equal? "a\xFFFD;b\n" (servers:ref (cadr (servers:of-method "eight" "textDocument/didOpen")) "params" "textDocument" "text"))
      (buffers:replace! raw 3 4 "c")
      (test-runner:wait-until (lambda () (= 3 (length (servers:of-method "eight" "textDocument/didChange")))))
      (check-equal? '(("start" ("line" . 0) ("character" . 4)) ("end" ("line" . 0) ("character" . 5)))
                    (servers:ref (cadr (list-ref (changes "eight") 2)) 0 "range"))))
  (tables:set! lsp:language-servers "fakelang" (list alpha)))

(test "an answer is counted on the content of the version its request saw, however many edits came since"
  (let ([asked-at (buffers:version a)])
    (check-equal? "Sono\n" (servers:text a))
    (for-each (lambda (i) (buffers:replace! a 1 1 "\n")) '(1 2 3))
    (check-equal? '(2 4)
                  (call-with-values
                    (lambda () (lsp:range-bounds c a '(("start" ("line" . 0) ("character" . 1)) ("end" ("line" . 0) ("character" . 3))) asked-at))
                    list))
    (check-equal? "on" (document:text (buffers:document-at a asked-at) 2 4))))

(test "a report about a version the buffer's log no longer holds is dropped"
  (define (publish! version message)
    (servers:send! c
      `(("jsonrpc" . "2.0") ("method" . "textDocument/publishDiagnostics")
        ("params" ("uri" . ,(lsp:path->uri a-path)) ("version" . ,version)
                  ("diagnostics" . #((("range" ("start" ("line" . 0) ("character" . 0)) ("end" ("line" . 0) ("character" . 1)))
                                      ("severity" . 1) ("message" . ,message))))))))
  (let ([now (buffers:version a)])
    (publish! now "now")
    (test-runner:wait-until (lambda () (pair? (diagnostics:in a))))
    (check-equal? '("now") (map diagnostics:diagnostic-message (diagnostics:in a)))
    (do ([i 0 (+ i 1)]) ((= i 1100)) (buffers:with-silent-edits a (buffers:replace! a 1 1 "x") (buffers:replace! a 1 2 "")))
    (timers:set-idle! #t)
    (test-runner:wait-until (lambda () (not (buffers:document-at a now))))
    (publish! now "too old")
    (publish! (buffers:version a) "newest")
    (test-runner:wait-until (lambda () (equal? '("newest") (map diagnostics:diagnostic-message (diagnostics:in a)))))))
