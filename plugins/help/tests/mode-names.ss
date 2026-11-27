(import (tuna) (test) (test-user) (views) (buffers) (layout) (modes) (options) (tables) (keys) (editing) (help) (help-test)
        (modes-test fill) (modes-test view))

(test "C-h m heads each minor mode on with its name, a state mode's too, and one put in modes:minor-modes alone with its lighter"
  (let ([plain (lambda () #t)])
    (test-user:show! "|x")
    (let ([b (views:buffer (layout:selected-view))])
      (tables:set! modes:minor-modes plain 0)
      (tables:set! modes:lighters plain "Plain")
      (buffers:with-buffer b (options:set-local! modes-test/fill:mode #t))
      (modes-test/view:set-viewing! b #t)
      (test-user:press! "C-h m")
      (let ([outline (help-test:outline)])
        (check (member "## modes-test/fill:mode" outline))
        (check (member "## modes-test/view:mode" outline))
        (check (member "## Plain" outline)))
      (tables:remove! modes:minor-modes plain))))

(test "C-h b heads a named minor mode's keymap with the mode's name"
  (keys:bind! modes-test/fill:keymap "C-c f" editing:forward-char)
  (test-user:press! "C-h b")
  (check (member "## modes-test/fill:mode" (help-test:outline))))
