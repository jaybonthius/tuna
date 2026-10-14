;;; Commands that never finish, for tests of quitting with C-g: C-c l loops
;;; checking for quit; C-c L loops without checking, so only a forced quit
;;; stops it.
prelude: :gerbil/core

(import :tuna/services/commands
        :tuna/kernel
        :tuna/services/keys)
(export endless-commands-plugin)

(defplugin (endless-commands-plugin ctx)
  "Endless commands to quit with C-g: C-c l checks for quit, C-c L does not."
  requires: [commands-service input-service]
  optional: [messages-service]
  (define-command ctx (loop-forever) "Loop until quit, checking for quit."
    (message "Looping forever, checking for quit. Press C-g.")
    (redisplay)
    (let lp () (check-quit) (lp)))
  (define-command ctx (loop-forever-ignoring-quit) "Loop until quit, never checking for quit."
    (message "Looping forever without checking for quit. Press C-g.")
    (redisplay)
    ;; Counting keeps gxc -O from hanging on an empty self-loop.
    (let lp ((n 0)) (lp (fxand (fx1+ n) #xffff))))
  (keymap-set ctx "C-c l" 'loop-forever)
  (keymap-set ctx "C-c L" 'loop-forever-ignoring-quit))
