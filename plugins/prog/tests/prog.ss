(import (tuna) (test) (test-user) (modes) (prog) (buffers) (layout) (keys) (hooks) (options) (tables) (files) (editing) (echo-area) (views) (chez-scheme) (chez-scheme-test scheme-buffers))

(define (require-final-newline) (options:set-local! files:require-final-newline #t))

(hooks:add! prog:mode-hook require-final-newline)

(test "prog:mode has no parent, the keymap prog:keymap, the hook prog:mode-hook and the lighter Prog"
  (check-equal? '(prog:mode) (modes:ancestry prog:mode))
  (check (eq? prog:keymap (tables:ref modes:keymaps prog:mode #f)))
  (check (eq? prog:mode-hook (tables:ref modes:hooks prog:mode #f)))
  (check-equal? "Prog" (modes:lighter prog:mode)))

(test "a language names it as its parent, and a plugin tests a buffer's mode with derived?"
  (let ([program (chez-scheme-test/scheme-buffers:scheme-buffer "program.ss" "(display 1)\n")])
    (check-equal? (list chez-scheme:mode prog:mode) (modes:ancestry chez-scheme:mode))
    (check-equal? #t (buffers:with-buffer program (modes:derived? (modes:major-mode (buffers:current)) prog:mode)))))

(test "the configuration's hook entry applies in every programming buffer"
  (let ([program (chez-scheme-test/scheme-buffers:scheme-buffer "final.ss" "(display 1)\n")] [plain (buffers:make "plain" "x")])
    (check-equal? '(#t #f) (list (buffers:with-buffer program (files:require-final-newline)) (buffers:with-buffer plain (files:require-final-newline))))))

(test "prog:mode-hook runs before the language's own hook"
  (let* ([calls '()] [prog-entry (lambda () (set! calls (cons 'prog calls)))] [scheme-entry (lambda () (set! calls (cons 'scheme calls)))])
    (hooks:add! prog:mode-hook prog-entry)
    (hooks:add! chez-scheme:mode-hook scheme-entry)
    (chez-scheme-test/scheme-buffers:scheme-buffer "order.ss" "x\n")
    (check-equal? '(prog scheme) (reverse calls))
    (hooks:remove! prog:mode-hook prog-entry)
    (hooks:remove! chez-scheme:mode-hook scheme-entry)))

(test "prog:keymap starts empty, and its keys apply in every buffer derived from prog:mode, after the language's own"
  (check-equal? '() (keys:bindings prog:keymap))
  (keys:bind! prog:keymap "C-c C-u" editing:upcase-region)
  (test-user:show! "|(display 1)\n")
  (modes:set-major-mode chez-scheme:mode (buffers:find "*test*"))
  (let ([found (views:call-with-view (layout:selected-view) (lambda () (keys:active-keymaps (test-user:client))))])
    (check (memq prog:keymap found))
    (check (< (length (memq prog:keymap found)) (length (memq chez-scheme:keymap found)))))
  (test-user:press! "C-SPC C-e C-c C-u")
  (check-equal? "(DISPLAY 1)|\n" (test-user:text)))
