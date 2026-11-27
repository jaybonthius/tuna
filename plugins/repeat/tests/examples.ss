(import (tuna) (test) (test-user) (tables) (keys) (echo-area) (layout-split) (repeat))

(test "layout-split's resizing repeats: after C-x }, each } or { goes on resizing, and any other key ends it"
  (let* ([runs '()]
         [note (lambda (name) (lambda (next . args) (set! runs (cons name runs)) (apply next args)))]
         [enlarged (note 'enlarge)] [shrunk (note 'shrink)])
    (test-user:show! "|text")
    (test-user:press! "C-x 3")
    (advice-add! layout-split:enlarge enlarged)
    (advice-add! layout-split:shrink shrunk)
    (test-user:press! "C-x } } } {")
    (check-equal? '(enlarge enlarge enlarge shrink) (reverse runs))
    (check (memq layout-split:resize-keymap (keys:active-keymaps (test-user:client))))
    (check-equal? "Repeat with }, {" (echo-area:current-message))
    (test-user:press! "C-g")
    (check (not (memq layout-split:resize-keymap (keys:active-keymaps (test-user:client)))))
    (advice-remove! layout-split:enlarge enlarged)
    (advice-remove! layout-split:shrink shrunk)))
