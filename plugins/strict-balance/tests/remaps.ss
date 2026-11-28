(import (tuna) (test) (test-user) (options) (keys) (buffers) (views) (layout) (editing) (strict-balance) (sexp-test scene))

(test "with the mode on, every one of editing's typing, deleting and killing commands runs strict balance's own, and no key is bound"
  (check-equal? '() (keys:bindings strict-balance:keymap))
  (let ([b (sexp-test/scene:show! "(a|)")])
    (buffers:with-buffer b (options:set-local! strict-balance:mode #t))
    (check-equal?
      (list strict-balance:self-insert strict-balance:delete-backward-char strict-balance:delete-char
            strict-balance:delete-forward-char strict-balance:kill-line strict-balance:kill-whole-line
            strict-balance:kill-word strict-balance:backward-kill-word strict-balance:kill-region
            strict-balance:delete-indentation)
      (map (lambda (command) (views:with-view (layout:selected-view) (keys:command-remapping (test-user:client) command)))
           (list editing:self-insert editing:delete-backward-char editing:delete-char editing:delete-forward-char
                 editing:kill-line editing:kill-whole-line editing:kill-word editing:backward-kill-word
                 editing:kill-region editing:delete-indentation)))))
