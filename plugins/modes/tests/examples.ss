(import (tuna) (test) (modes) (prog) (python) (auto-mode) (files) (buffers) (views) (layout) (keys) (commands) (hooks) (options)
        (tables) (editing) (help) (lsp) (test-user) (buffers-test) (modes-test text) (modes-test fill) (modes-test view))

(define (home-file name) (string-append (getenv "HOME") "/" name))

(define (write-file! name text)
  (call-with-output-file (home-file name) (lambda (p) (put-string p text)) 'replace))

(define (local option b) (buffers:with-buffer b (option)))

(options:set! auto-mode:default-mode modes-test/text:mode)
(tables:set! modes:lighters python:mode "Py")
(define (fill-in-python) (options:set-local! modes-test/fill:mode #t))
(hooks:add! python:mode-hook fill-in-python)

(mkdir (home-file "src"))
(mkdir (home-file "src/tools"))
(write-file! "src/tools/build.py" "import sys\n")
(write-file! "notes.txt" "Buy milk.\n")

(define build (files:visit (home-file "src/tools/build.py")))
(define notes-buffer (files:visit (home-file "notes.txt")))
(define notes (views:make notes-buffer))

(test "the configuration's example: the default mode, a lighter and a hook entry in Python buffers"
  (check-equal? modes-test/text:mode (modes:major-mode notes-buffer))
  (check-equal? '("Py" "Text" "Fill" "Fundamental") (map modes:lighter (list python:mode modes-test/text:mode modes-test/fill:mode modes:fundamental)))
  (check-equal? python:mode (modes:major-mode build))
  (check-equal? #t (local modes-test/fill:mode build)))

(test "the examples of ancestry and derived?"
  (check-equal? (list python:mode prog:mode) (modes:ancestry python:mode))
  (check-equal? #t (buffers:with-buffer build (modes:derived? (modes:major-mode (buffers:current)) prog:mode))))

(test "the examples of the minor modes on in a view and their lighters"
  (views:with-view notes (options:set-local! modes-test/fill:mode #t))
  (let ([on (modes:active-minor-modes notes)])
    (check (memq modes-test/fill:mode on))
    (check-equal? "Fill" (modes:lighter modes-test/fill:mode))
    (check (for-all (lambda (m) (or (memq m (list modes-test/fill:mode)) (not (modes:lighter m)))) on))))

(test "a state minor mode reads its plugin's own table"
  (check-equal? #f (memq modes-test/view:mode (modes:active-minor-modes notes)))
  (modes-test/view:set-viewing! notes-buffer #t)
  (check (memq modes-test/view:mode (modes:active-minor-modes notes)))
  (check-equal? "View" (modes:lighter modes-test/view:mode))
  (modes-test/view:set-viewing! notes-buffer #f))

(test "removing a lighter leaves the mode without one"
  (tables:remove! modes:lighters modes-test/fill:mode)
  (check-equal? #f (modes:lighter modes-test/fill:mode)))

(test "the user removes a setup, binds a key and turns fill mode on in every buffer derived from prog:mode"
  (hooks:remove! python:mode-hook fill-in-python)
  (keys:bind! python:keymap "C-c C-u" editing:upcase-region)
  (hooks:add! prog:mode-hook (lambda () (options:set-local! modes-test/fill:mode #t)))
  (modes:set-major-mode python:mode build)
  (check-equal? #t (local modes-test/fill:mode build))
  (views:set-buffer! (layout:selected-view) build)
  (check-equal? 'editing:upcase-region
                (commands:command-name (views:call-with-view (layout:selected-view) (lambda () (keys:lookup (test-user:client) "C-c C-u"))))))

(commands:define-command (python-run) "Runs the buffer's Python." (void))

(test "the example of a command marked for a mode"
  (tables:set! commands:command-modes python-run (list python:mode))
  (views:set-buffer! (layout:selected-view) build)
  (check-equal? #t (modes:command-for-view? python-run (layout:selected-view)))
  (views:set-buffer! (layout:selected-view) notes-buffer)
  (check-equal? #f (modes:command-for-view? python-run (layout:selected-view))))

(test "the examples of switching a major mode by hand and refusing a plugin-only one"
  (let ([b (buffers:make "build" "x")])
    (modes:switch-major-mode python:mode b)
    (check-equal? python:mode (modes:major-mode b)))
  (help:describe-mode (layout:selected-view))
  (check-raises (lambda (c) (and (who-condition? c) (eq? 'modes:switch-major-mode (condition-who c))))
                (modes:switch-major-mode prog:mode (buffers:find "*Help*"))))

(test "the examples of toggling a minor mode and naming minor modes"
  (modes:toggle-minor-mode modes-test/fill:mode notes-buffer #t)
  (check-equal? #t (buffers:with-buffer notes-buffer (modes-test/fill:mode)))
  (check-equal? 'modes-test/fill:mode (modes:name modes-test/fill:mode))
  (check-equal? 'lsp:managed? (modes:name lsp:managed?)))
