(import (tuna) (test) (test-user) (views) (buffers) (layout) (layout-split) (tables) (commands) (keys) (transient)
        (transient-test) (transient-test magit) (transient-test pi) (transient-test python))

(test-user:show! "|one\ntwo\n")

(test "the page's configuration shows menus at the bottom of the screen, locked, and q closes one"
  (keys:bind! transient:keymap "q" transient:quit)
  (tables:set! layout:display-rules transient:buffer?
    (layout-split:display-at-side (layout:direction down) 95 'content '((locked . #t))))
  (test-user:press! "C-c m")
  (check-equal? '("Merge" ("Arguments" ("- f" "Fast-forward only" "--ff-only") ("- n" "No fast-forward" "--no-ff") ("- s" "Strategy" "--strategy="))
                  ("Actions" ("m" "Merge")))
                (transient-test:menu))
  (check (layout:locked? (layout:view-node (transient-test:popup-view))))
  (test-user:press! "q")
  (check-equal? #f (transient-test:menu))
  (tables:remove! layout:display-rules transient:buffer?))

(test "the merge menu's command reads the arguments set, and a user removes an entry"
  (transient:remove! transient-test/magit:merge-menu "- s")
  (test-user:press! "C-c m - f m")
  (check-equal? '(("--ff-only")) (transient-test/magit:merges)))

(test "the chat menu: a toggles auto-compaction and the menu stays to show the new state; a command entry closes it"
  (commands:run transient-test/pi:show-menu)
  (test-user:settle)
  (check-equal? '("Pi, notes" ("Session" ("n" "New") ("r" "Resume") ("N" "Rename")) ("Model" ("m" "Model (sonnet)") ("a" "Auto-compact (off)")))
                (transient-test:menu))
  (test-user:press! "a")
  (check-equal? '("Model" ("m" "Model (sonnet)") ("a" "Auto-compact (on)")) (list-ref (transient-test:menu) 2))
  (test-user:press! "m")
  (check-equal? '(#f (model)) (list (transient-test:menu) (transient-test/pi:ran)))
  (commands:run transient-test/pi:show-menu)
  (test-user:settle)
  (check-equal? '("Model" ("m" "Model (opus)") ("a" "Auto-compact (on)")) (list-ref (transient-test:menu) 2))
  (test-user:press! "C-g"))

(commands:define-command (show-templates) "Shows the templates." (transient:show! transient-test/pi:templates-menu))

(test "the chat's templates, computed at each draw, in a menu of their own"
  (commands:run show-templates)
  (test-user:settle)
  (check-equal? '(("Templates" ("a" "Review") ("b" "Explain"))) (transient-test:menu))
  (test-user:press! "b")
  (check-equal? '("Explain" model) (transient-test/pi:ran)))

(test "a mode's keys shown as a menu"
  (commands:run transient-test/python:python-keys)
  (test-user:settle)
  (check-equal? '((("C-c C-c" "transient-test/python:send-buffer") ("C-c C-z" "transient-test/python:switch-to-shell")
                   ("C-c C-s" "Python's shell keys.")))
                (transient-test:menu))
  (test-user:press! "C-g"))
