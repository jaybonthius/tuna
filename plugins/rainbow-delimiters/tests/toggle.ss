(import (tuna) (test) (test-runner) (test-user) (modes) (buffers) (views) (layout) (options) (echo-area) (minibuffer) (completion)
        (command-picker) (syntax) (chez-scheme) (rainbow-delimiters) (chez-scheme-test scheme-buffers) (completion-test sessions))

(test "modes:toggle-minor-mode offers the mode; turned on with a local value, it colours the brackets by depth, and the echo area says so"
  (let ([notes (chez-scheme-test/scheme-buffers:scheme-buffer "notes.ss" "(a [b])\n")])
    (views:set-buffer! (layout:selected-view) notes)
    (check-equal? #f (buffers:with-buffer notes (rainbow-delimiters:mode)))
    (test-user:press! "M-x")
    (test-user:type! "modes:toggle-minor-mode")
    (test-user:press! "RET")
    (test-user:type! "rainbow-delimiters:mode")
    (test-user:press! "RET")
    (check-equal? #f (completion-test/sessions:prompt))
    (check-equal? '(#t #t #f) (list (buffers:with-buffer notes (options:local? rainbow-delimiters:mode))
                                    (buffers:with-buffer notes (rainbow-delimiters:mode)) (rainbow-delimiters:mode)))
    (test-runner:wait-until
      (lambda () (equal? '((1 2 ((bracket . 1))) (4 5 ((bracket . 2))) (6 7 ((bracket . 2))) (7 8 ((bracket . 1))))
                         (chez-scheme-test/scheme-buffers:brackets notes))))
    (check-equal? "rainbow-delimiters:mode enabled in current buffer" (echo-area:current-message))))
