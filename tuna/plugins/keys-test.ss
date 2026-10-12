(import :std/test
        :tuna/kernel
        :tuna/services/keys
        :tuna/services/echo-area
        :tuna/plugins/keys
        :tuna/plugins/echo-area)
(export keys-test)

(def (keydown key ctrl?: (ctrl? #f) alt?: (alt? #f) shift?: (shift? #f)
              meta?: (meta? #f) composing?: (composing? #f))
  (make-key-event "test-client" 1 key "" 0 #f composing? alt? ctrl? meta? shift?))

(defplugin (binds-a ctx)
  "Binds C-c x to command-a."
  (keymap-set ctx "C-c x" 'command-a))

(defplugin (binds-b ctx)
  "Binds C-c x to command-b."
  (keymap-set ctx "C-c  x" 'command-b))

(def (binding keys)
  (let (e (key-binding keys))
    (and e (entry-value e))))

(def (with-keys thunk)
  (parameterize ((current-kernel (new-kernel)))
    (activate-plugin! echo-area-plugin)
    (activate-plugin! keys-plugin)
    (thunk)))

(def (resolve event)
  (let (resolved (Input-resolve-event! (Input (service-provider input-service)) event))
    (and resolved (command-name resolved))))

(def keys-test
  (test-suite "tuna/plugins/keys"
    (test-case "browser keys are described in Emacs key syntax"
      (check (key-description (keydown "a")) => "a")
      (check (key-description (keydown "c" ctrl?: #t)) => "C-c")
      (check (key-description (keydown "x" ctrl?: #t alt?: #t)) => "C-M-x")
      (check (key-description (keydown "L" shift?: #t)) => "L")
      (check (key-description (keydown "ArrowLeft" shift?: #t)) => "S-<left>")
      (check (key-description (keydown " ")) => "SPC")
      (check (key-description (keydown "Enter")) => "RET")
      (check (key-description (keydown "F5")) => "<f5>")
      (check (key-description (keydown "s" meta?: #t)) => "s-s")
      (check (key-description (keydown "Control" ctrl?: #t)) => #f)
      (check (key-description (keydown "Process" composing?: #t)) => #f))

    (test-case "two plugins binding the same key survive deactivation in either order"
      (with-keys
       (lambda ()
         (activate-plugin! binds-a)
         (activate-plugin! binds-b)
         (check (binding "C-c x") => 'command-b)
         (deactivate-plugin! binds-a)
         (check (binding "C-c x") => 'command-b)
         (activate-plugin! binds-a)
         (check (binding "C-c x") => 'command-a)
         (deactivate-plugin! binds-b)
         (check (binding "C-c x") => 'command-a)
         (activate-plugin! binds-b)
         (deactivate-plugin! binds-b)
         (check (binding "C-c x") => 'command-a)
         (deactivate-plugin! binds-a)
         (check (binding "C-c x") => #f))))

    (test-case "prefix keys wait for the rest of the sequence; C-g cancels"
      (with-keys
       (lambda ()
         (defplugin (commands ctx)
           "A command bound under C-c."
           (define-command ctx (command-a) "A." (void))
           (keymap-set ctx "C-c x" 'command-a))
         (activate-plugin! commands)
         (check (resolve (keydown "c" ctrl?: #t)) => #f)
         (check (current-message) => "C-c-")
         (check (resolve (keydown "Control" ctrl?: #t)) => #f)
         (check (resolve (keydown "x")) => 'command-a)
         (check (resolve (keydown "c" ctrl?: #t)) => #f)
         (check (resolve (keydown "z")) => #f)
         (check (current-message) => "C-c z is undefined")
         (check (resolve (keydown "c" ctrl?: #t)) => #f)
         (check (resolve (keydown "g" ctrl?: #t)) => 'keyboard-quit)
         (check (resolve (keydown "x")) => #f)
         (check (current-message) => "x is undefined"))))

    (test-case "the innermost input target's keymap comes first, including for C-g"
      (with-keys
       (lambda ()
         (defplugin (targets ctx)
           "Commands for the global keymap and two input targets."
           (for-each (lambda (name) (context-define-command! ctx name void))
                     '(global-x outer-x inner-x inner-quit))
           (keymap-set ctx "C-c x" 'global-x))
         (activate-plugin! targets)
         (let ((outer (make-input-target 'outer (new-keymap)))
               (inner (make-input-target 'inner (new-keymap))))
           (defplugin (target-keys ctx)
             "Binds keys in the two targets' keymaps."
             (keymap-set-in ctx (input-target-keymap outer) "C-c x" 'outer-x)
             (keymap-set-in ctx (input-target-keymap inner) "C-c x" 'inner-x)
             (keymap-set-in ctx (input-target-keymap inner) "C-g" 'inner-quit))
           (activate-plugin! target-keys)
           (push-input-target! outer)
           (push-input-target! inner)
           (resolve (keydown "c" ctrl?: #t))
           (check (resolve (keydown "x")) => 'inner-x)
           (check (resolve (keydown "g" ctrl?: #t)) => 'inner-quit)
           (remove-input-target! inner)
           (resolve (keydown "c" ctrl?: #t))
           (check (resolve (keydown "x")) => 'outer-x)
           (check (resolve (keydown "g" ctrl?: #t)) => 'keyboard-quit)
           (remove-input-target! outer)
           (resolve (keydown "c" ctrl?: #t))
           (check (resolve (keydown "x")) => 'global-x)))))

    (test-case "only C-g is the quit key"
      (with-keys
       (lambda ()
         (let (input (Input (service-provider input-service)))
           (check (Input-quit-event? input (keydown "g" ctrl?: #t)) => #t)
           (check (Input-quit-event? input (keydown "g")) => #f)
           (check (Input-quit-event? input (keydown "g" ctrl?: #t alt?: #t)) => #f)))))))
