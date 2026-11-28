(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (buffers) (document) (views) (layout) (files)
        (editing) (outline) (lsp) (lsp-test servers))

(options:set! lsp:send-changes-delay 0.05 outline:idle-delay 0.05)

(lsp:define-server symbols (lsp-test/servers:fake-command "symbols"))

(define (position line character) `(("line" . ,line) ("character" . ,character)))

(define (range line from to-line to)
  `(("start" . ,(position line from)) ("end" . ,(position to-line to))))

(define (symbol name kind whole selection . children)
  `(("name" . ,name) ("kind" . ,kind) ("range" . ,whole) ("selectionRange" . ,selection)
    ("children" . ,(list->vector children))))

(define cart-path (string-append lsp-test/servers:project "/cart.fk"))

(define cart-text "class Cart:\n  def total(self):\n    pass\n  def add(self):\n    pass\ndef helper():\n  pass\nx = 1\n")

(lsp-test/servers:write-file! cart-path cart-text)

;; total is listed after add, and helper's child stray lies outside
;; helper, on the last line.
(define tree
  (vector (symbol "Cart" 5 (range 0 0 4 8) (range 0 6 0 10)
            (symbol "add" 6 (range 3 2 4 8) (range 3 6 3 9))
            (symbol "total" 6 (range 1 2 2 8) (range 1 6 1 11)))
          (symbol "helper" 12 (range 5 0 6 6) (range 5 4 5 10)
            (symbol "stray" 13 (range 7 0 7 5) (range 7 0 7 1)))))

(define (configure! answer)
  (lsp-test/servers:configure! "symbols"
    '(capabilities ("textDocumentSync" . 2) ("documentSymbolProvider" . #t))
    `(responses ("textDocument/documentSymbol" . ,answer))
    '(name . "symbols")))

(configure! tree)

(tables:set! lsp:language-servers "fakelang" (list symbols))

(hooks:add! lsp-test/servers:fake-mode-hook lsp:ensure)

(define forgotten '())

(define (note-forget next b) (set! forgotten (cons b forgotten)) (next b))

(advice-add! outline:forget! note-forget)

(define cart (lsp-test/servers:visit! cart-path))

(lsp-test/servers:wait-for "symbols" "textDocument/didOpen")

(define (place b p)
  (let ([doc (buffers:document b)]) (list (- (document:line doc p) 1) (document:column doc p))))

(define (entries o)
  (let ([found '()])
    (outline:walk o
      (lambda (e ancestors)
        (set! found (cons (list (length ancestors) (outline:entry-name e) (outline:entry-kind e)
                                (place cart (outline:entry-point e)))
                          found))))
    (reverse found)))

(define (asked)
  (outline:forget! cart)
  (outline:get cart))

(test "initialize offers documentSymbol with a hierarchy, and a server becoming ready or managing a buffer forgets its outline"
  (check-equal? #t (lsp-test/servers:ref (lsp-test/servers:last-of "symbols" "initialize")
                                         "params" "capabilities" "textDocument" "documentSymbol"
                                         "hierarchicalDocumentSymbolSupport"))
  (check (memq cart forgotten)))

(test "a DocumentSymbol tree becomes entries with its names' places and kinds, children sorted, a child outside its parent at the parent's level"
  (check-equal? '((0 "Cart" class (0 6)) (1 "total" method (1 6)) (1 "add" method (3 6)) (0 "helper" function (5 4))
                  (0 "stray" variable (7 0)))
                (entries (asked)))
  (check-equal? (buffers:version cart) (outline:version (outline:get cart))))

(test "SymbolInformation answers give flat entries, their points at their ranges' starts; null gives an outline with no roots"
  (configure! (vector `(("name" . "Cart") ("kind" . 5) ("location" ("uri" . ,(lsp:path->uri cart-path)) ("range" . ,(range 0 0 4 8))))
                      `(("name" . "helper") ("kind" . 12) ("location" ("uri" . ,(lsp:path->uri cart-path)) ("range" . ,(range 5 0 6 6))))))
  (check-equal? '((0 "Cart" class (0 0)) (0 "helper" function (5 0))) (entries (asked)))
  (configure! 'null)
  (check-equal? '() (outline:roots (asked)))
  (configure! tree))

(test "the server's outline wins over a source of the language's own; with document-symbol ignored the source gives #f and the other answers"
  (let ([own (lambda (b) (and (eq? b cart) (outline:make-outline b (buffers:version b)
                                               (list (outline:make-entry "own" 'module 1 5 1)))))])
    (hooks:add! outline:sources own)
    (check-equal? "Cart" (outline:entry-name (car (outline:roots (asked)))))
    (buffers:with-buffer cart (options:set-local! lsp:ignored-capabilities (lsp:capabilities document-symbol)))
    (check-equal? #f (lsp:outline-source cart))
    (check-equal? '("own") (map outline:entry-name (outline:roots (asked))))
    (buffers:with-buffer cart (options:unset-local! lsp:ignored-capabilities))
    (hooks:remove! outline:sources own)))

(test "a buffer no connection manages has no answer"
  (check-equal? #f (lsp:outline-source (buffers:make "plain" "text"))))

(test "an edit made while the server answers leaves the outline at the version asked, and outline:map carries it"
  (configure! (list 'delay 0.5 tree))
  (let ([before (buffers:version cart)] [got #f]
        [asked (length (lsp-test/servers:of-method "symbols" "textDocument/documentSymbol"))])
    (outline:forget! cart)
    (spawn-task (lambda (restore) (set! got (outline:get cart))))
    (lsp-test/servers:wait-for "symbols" "textDocument/documentSymbol" (+ asked 1))
    (buffers:replace! cart (editing:line-position cart 1) (editing:line-position cart 1) "# a note\n")
    (test-runner:wait-until (lambda () got))
    (check-equal? before (outline:version got))
    (check-equal? '(1 6) (place cart (outline:map got (outline:entry-point (car (outline:roots got))))))
    (buffers:replace! cart (editing:line-position cart 1) (editing:line-position cart 2) "")
    (configure! tree)))
