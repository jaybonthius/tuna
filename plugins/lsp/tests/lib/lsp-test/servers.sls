#!tuna
(import (buffers) (document) (views) (layout) (files) (modes) (tables) (hooks) (options) (commands) (auto-mode) (ask) (minibuffer) (json)
        (test-runner) (test-user) (lsp))

(define home (getenv "HOME"))

(define project (string-append home "/project"))

(define %said '())

(define (said!)
  (let ([s (reverse %said)])
    (set! %said '())
    s))

(define (%config-of name) (string-append home "/" name ".config"))

(define (%record-of name) (string-append home "/" name ".record"))

;; A fake server reads its answers from a file again before each
;; message, so a test changes them between steps.
(define (configure! name . settings)
  (let ([config (%config-of name)])
    (when (file-exists? config) (delete-file config))
    (with-output-to-file config (lambda () (write settings)))))

;; The fake server is a Chez script, not a test file, so it sits in lib/;
;; a test reaches its plugin's files in the install's copy.
(define (fake-command name)
  (let ([tuna (car (command-line))])
    (list tuna "--script" (string-append (path-parent tuna) "/plugins/lsp/tests/lib/fake-server.ss")
          (string-append (path-parent tuna) "/libraries") (%config-of name) (%record-of name))))

;; Each process of a server writes a record of its own, numbered in the
;; order they started. The server may be writing a long message as the
;; record is read, so text after the last line break is not yet a message.
(define (received name)
  (let next ([n 1] [acc '()])
    (let ([path (format "~a.~a" (%record-of name) n)])
      (if (file-exists? path)
          (let ([all (call-with-input-file path get-string-all)])
            (let loop ([start 0] [i 0] [acc acc])
              (cond
                [(or (eof-object? all) (= i (string-length all))) (next (+ n 1) acc)]
                [(char=? (string-ref all i) #\newline) (loop (+ i 1) (+ i 1) (cons (string->json (substring all start i)) acc))]
                [else (loop start (+ i 1) acc)])))
          (reverse acc)))))

(define (ref v . keys)
  (let loop ([v v] [keys keys])
    (cond
      [(null? keys) v]
      [(and (list? v) (assoc (car keys) v)) => (lambda (p) (loop (cdr p) (cdr keys)))]
      [(and (vector? v) (fixnum? (car keys))) (loop (vector-ref v (car keys)) (cdr keys))]
      [else #f])))

(define (methods name) (map (lambda (m) (ref m "method")) (received name)))

(define (of-method name method) (filter (lambda (m) (equal? (ref m "method") method)) (received name)))

(define (last-of name method)
  (let ([ms (of-method name method)])
    (and (pair? ms) (list-ref ms (- (length ms) 1)))))

(define wait-for
  (case-lambda
    [(name method) (wait-for name method 1)]
    [(name method count) (test-runner:wait-until (lambda () (>= (length (of-method name method)) count)))]))

(define (answered name id) (find (lambda (m) (equal? (ref m "id") id)) (received name)))

(define (write-file! path content)
  (let loop ([folder (path-parent path)])
    (unless (file-exists? folder)
      (loop (path-parent folder))
      (mkdir folder)))
  (when (file-exists? path) (delete-file path))
  (with-output-to-file path (lambda () (display content))))

(define (text b) (document:text (buffers:document b)))

(define (visit! path)
  (let ([b (files:visit path)])
    (layout:switch-to-buffer b)
    b))

(define (view) (layout:selected-view))

(define (send! c message) (lsp:notify c "fake/send" (list (cons "message" message))))

(define (publish! c path diagnostics)
  (send! c `(("jsonrpc" . "2.0") ("method" . "textDocument/publishDiagnostics")
             ("params" ("uri" . ,(lsp:path->uri path)) ("diagnostics" . ,(list->vector diagnostics))))))

(tables:define-table fake-keymap)

(hooks:define-hook fake-mode-hook)

(modes:define-major-mode fake-mode (keymap fake-keymap) (hook fake-mode-hook) (language "fakelang"))

(define (reports-during thunk)
  (map (lambda (c) (if (cancelled? c) 'cancelled (list (condition-who c) (condition-message c)))) (test-runner:reports-during thunk)))

(define %ended '())

;; A command may pause past test-user:settle, as when it waits for a
;; server, so a test that needs it done waits for its end.
(define (press-until-ended! keys command)
  (set! %ended '())
  (test-user:press! keys)
  (test-runner:wait-until (lambda () (memq command %ended))))

;; A command that asks a server before it asks the user shows its prompt
;; past test-user:settle.
(define (press-until-prompt! keys)
  (let ([before (minibuffer:current-prompt)])
    (test-user:press! keys)
    (test-runner:wait-until (lambda () (let ([p (minibuffer:current-prompt)]) (and p (not (eq? p before))))))
    (test-user:settle)))

(hooks:add! commands:after-command (lambda (command) (set! %ended (cons command %ended))))

(tables:set! auto-mode:file-names "fk" fake-mode)

(options:set! ask:message-writer (lambda (text) (set! %said (cons text %said))))

(for-each (lambda (folder) (unless (file-exists? folder) (mkdir folder))) (list project (string-append project "/.git")))
