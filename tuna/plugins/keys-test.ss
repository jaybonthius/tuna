(import :std/error
        :std/test
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

;; The name of the task EVENT resolves to, or #f.
(def (resolve event)
  (let (resolved (Input-resolve! (Input (service-provider input-service)) event))
    (and resolved (car resolved))))

(defplugin (defines-a ctx)
  "Defines command-shared as a."
  requires: [input-service]
  (define-command ctx (command-shared) "Runs a." 'a))

(defplugin (defines-b ctx)
  "Defines command-shared as b."
  requires: [input-service]
  (define-command ctx (command-shared) "Runs b." 'b))

;; What the effective command-shared returns when run, or #f.
(def (shared-result)
  (let (c (command-ref 'command-shared))
    (and c ((command-procedure c)))))

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

    (test-case "two plugins defining the same command survive deactivation in either order"
      (with-keys
       (lambda ()
         (activate-plugin! defines-a)
         (activate-plugin! defines-b)
         (check (shared-result) => 'b)
         (deactivate-plugin! defines-a)
         (check (shared-result) => 'b)
         (activate-plugin! defines-a)
         (check (shared-result) => 'a)
         (deactivate-plugin! defines-b)
         (check (shared-result) => 'a)
         (deactivate-plugin! defines-a)
         (check (command-ref 'command-shared) => #f))))

    (test-case "a failed activation leaves no command behind"
      (with-keys
       (lambda ()
         (defplugin (half-done ctx)
           "Defines a command, then fails."
           requires: [input-service]
           (define-command ctx (half-done-command) "Never usable." (void))
           (error "activation failed"))
         (check-exception (activate-plugin! half-done) Error?)
         (check (command-ref 'half-done-command) => #f)
         (check (plugin-active? half-done) => #f))))

    (test-case "commands record their plugin, source, and documentation"
      (with-keys
       (lambda ()
         (defplugin (documented ctx)
           "Defines one command."
           requires: [input-service]
           (define-command ctx (documented-command) "Does nothing." (void)))
         (activate-plugin! documented)
         (let (e (command-entry 'documented-command))
           (check (entry-owner e) => 'documented)
           (check (entry-doc e) => "Does nothing.")
           (check (and (string? (entry-source e))
                       (string-contains (entry-source e) "keys-test.ss"))
                  ? values))
         (check (command-doc (command-ref 'documented-command)) => "Does nothing."))))

    (test-case "a key resolves to its command's name and thunk"
      (with-keys
       (lambda ()
         (defplugin (binds-shared ctx)
           "Binds C-c a to command-shared."
           requires: [input-service]
           (keymap-set ctx "C-c a" 'command-shared))
         (activate-plugin! defines-a)
         (activate-plugin! binds-shared)
         (let (input (Input (service-provider input-service)))
           (Input-resolve! input (keydown "c" ctrl?: #t))
           (let (resolved (Input-resolve! input (keydown "a")))
             (check (car resolved) => 'command-shared)
             (check ((cdr resolved)) => 'a))))))

    (test-case "prefix keys wait for the rest of the sequence; C-g cancels"
      (with-keys
       (lambda ()
         (defplugin (commands ctx)
           "A command bound under C-c."
           requires: [input-service]
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
           requires: [input-service]
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

    (test-case "only C-g arrives as an interrupt"
      (with-keys
       (lambda ()
         (let (input (Input (service-provider input-service)))
           (check (Input-arrival input (keydown "g" ctrl?: #t)) => 'interrupt)
           (check (Input-arrival input (keydown "g")) => 'queue)
           (check (Input-arrival input (keydown "g" ctrl?: #t alt?: #t)) => 'queue)))))))
