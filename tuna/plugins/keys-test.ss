(import :std/error
        :std/test
        :tuna/kernel
        :tuna/services/keys
        :tuna/plugins/keys
        "../test-support/kernel"
        (only-in "../test-support/string-input" test-messages-plugin current-message))
(export keys-test)

(def (keydown key ctrl?: (ctrl? #f) alt?: (alt? #f) shift?: (shift? #f)
              meta?: (meta? #f) composing?: (composing? #f))
  (make-key-event "test-client" 1 key "" 0 #f composing? alt? ctrl? meta? shift?))

(def (pointer area part button: (button 1) clicks: (clicks 1) ctrl?: (ctrl? #f)
                 alt?: (alt? #f) shift?: (shift? #f) meta?: (meta? #f))
  (make-pointer-event "test-client" 1 button clicks alt? ctrl? meta? shift?
                      (make-posn area part #f 5)))

(defplugin (binds-a ctx)
  "Binds C-c x to command-a."
  (keymap-set ctx "C-c x" 'command-a))

(defplugin (binds-b ctx)
  "Binds C-c x to command-b."
  (keymap-set ctx "C-c  x" 'command-b))

(def (binding keys)
  (let (e (key-binding keys))
    (and e (entry-value e))))

(def keys-plugins
  [test-messages-plugin keys-plugin])

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
      (call-with-fresh-kernel keys-plugins
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
      (call-with-fresh-kernel keys-plugins
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
      (call-with-fresh-kernel keys-plugins
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
      (call-with-fresh-kernel keys-plugins
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
      (call-with-fresh-kernel keys-plugins
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
      (call-with-fresh-kernel keys-plugins
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
      (call-with-fresh-kernel keys-plugins
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

    (test-case "restarting the keys plugin re-registers a dependent's commands"
      (call-with-fresh-kernel keys-plugins
       (lambda ()
         (activate-plugin! defines-a)
         (check (shared-result) => 'a)
         (deactivate-plugin! keys-plugin)
         (check (plugin-active? defines-a) => #f)
         (activate-plugin! keys-plugin)
         (check (plugin-active? defines-a) => #t)
         (check (shared-result) => 'a)
         (let (quit (command-entry 'keyboard-quit))
           (check (entry-owner quit) => 'keys-plugin)
           (check (and (string? (entry-source quit))
                       (string-contains (entry-source quit) "plugins/keys.ss"))
                  ? values)))))

    (test-case "only C-g arrives as an interrupt"
      (call-with-fresh-kernel keys-plugins
       (lambda ()
         (let (input (Input (service-provider input-service)))
           (check (Input-arrival input (keydown "g" ctrl?: #t)) => 'interrupt)
           (check (Input-arrival input (keydown "g")) => 'queue)
           (check (Input-arrival input (keydown "g" ctrl?: #t alt?: #t)) => 'queue)
           (check (Input-arrival input (pointer 'tab-line 30)) => 'queue)))))

    (test-case "a click's Emacs names: modifiers, then double- or triple-, falling back to the single click"
      (check (pointer-event-names (pointer 'view 1)) => ["mouse-1"])
      (check (pointer-event-names (pointer 'view 1 button: 3 ctrl?: #t)) => ["C-mouse-3"])
      (check (pointer-event-names (pointer 'view 1 clicks: 2)) => ["double-mouse-1" "mouse-1"])
      (check (pointer-event-names (pointer 'view 1 clicks: 7 button: 2 alt?: #t shift?: #t meta?: #t))
             => ["M-S-s-triple-mouse-2" "M-S-s-double-mouse-2" "M-S-s-mouse-2"])
      (check (event-start (keydown "a")) => #f)
      (let (p (event-start (pointer 'tab-line 30)))
        (check (posn-area p) => 'tab-line)
        (check (posn-part p) => 30)
        (check (posn-revision p) => 5)))

    (test-case "a click is looked up under its part kind first, then without it, most specific name first"
      (call-with-fresh-kernel keys-plugins
       (lambda ()
         (defplugin (clicks ctx)
           "Commands bound to clicks."
           requires: [input-service]
           (for-each (lambda (name) (context-define-command! ctx name void))
                     '(tab-click tab-double-click any-click any-double-click))
           (keymap-set ctx "<tab-line> <mouse-1>" 'tab-click)
           (keymap-set ctx "<mouse-1>" 'any-click)
           (keymap-set ctx "<double-mouse-1>" 'any-double-click)
           (keymap-set ctx "<tab-line> <C-double-mouse-1>" 'tab-double-click))
         (activate-plugin! clicks)
         (check (resolve (pointer 'tab-line 30)) => 'tab-click)
         (check (resolve (pointer 'view 12)) => 'any-click)
         ;; A double click on a tab falls back to the tab's single click
         ;; before leaving the part kind out.
         (check (resolve (pointer 'tab-line 30 clicks: 2)) => 'tab-click)
         (check (resolve (pointer 'view 12 clicks: 2)) => 'any-double-click)
         (check (resolve (pointer 'tab-line 30 clicks: 3 ctrl?: #t)) => 'tab-double-click)
         (check (resolve (pointer 'view 12 clicks: 3)) => 'any-double-click)
         (check (pointer-event-start (Keys-last-command-event (Keys (service-provider input-service))))
                ? posn?))))

    (test-case "an unbound click says so, ends a pending prefix, and leaves the echo area otherwise"
      (call-with-fresh-kernel keys-plugins
       (lambda ()
         (defplugin (prefixed ctx)
           "A command under C-c, and one on a tab click."
           requires: [input-service]
           (context-define-command! ctx 'command-a void)
           (keymap-set ctx "C-c x" 'command-a)
           (keymap-set ctx "<tab-line> <mouse-1>" 'command-a))
         (activate-plugin! prefixed)
         (message "kept")
         (check (resolve (pointer 'tab-line 30)) => 'command-a)
         (check (current-message) => "kept")
         (check (resolve (pointer 'tab-line 30 button: 2 clicks: 2)) => #f)
         (check (current-message) => "<tab-line> <double-mouse-2> is undefined")
         (check (resolve (keydown "c" ctrl?: #t)) => #f)
         (check (resolve (pointer 'tab-line 30)) => #f)
         (check (current-message) => "C-c <tab-line> <mouse-1> is undefined")
         (check (resolve (keydown "x")) => #f)
         (check (current-message) => "x is undefined"))))

    (test-case "part-clickable? is true for a part kind whose plain click has a binding"
      (call-with-fresh-kernel keys-plugins
       (lambda ()
         (defplugin (tab-clicks ctx)
           "Binds a middle click on a tab."
           requires: [input-service]
           (keymap-set ctx "<tab-line> <mouse-2>" 'command-a))
         (check (part-clickable? 'tab-line) => #f)
         (activate-plugin! tab-clicks)
         (check (part-clickable? 'tab-line) => #t)
         (check (part-clickable? 'view) => #f))))

    (test-case "keymap-clickable? looks for a plain click with or without the part kind"
      (call-with-fresh-kernel keys-plugins
       (lambda ()
         (let ((prefixed (new-keymap))
               (plain (new-keymap))
               (other (new-keymap)))
           (defplugin (node-clicks ctx)
             "Binds clicks and keys in three keymaps."
             requires: [input-service]
             (keymap-set-in ctx prefixed "<view> <mouse-3>" 'command-a)
             (keymap-set-in ctx plain "<mouse-1>" 'command-a)
             (keymap-set-in ctx other "<C-mouse-1>" 'command-a)
             (keymap-set-in ctx other "RET" 'command-a))
           (check (keymap-clickable? plain 'view) => #f)
           (activate-plugin! node-clicks)
           (check (keymap-clickable? prefixed 'view) => #t)
           (check (keymap-clickable? prefixed 'tab-line) => #f)
           (check (keymap-clickable? plain 'view) => #t)
           (check (keymap-clickable? other 'view) => #f)))))

    (test-case "the keymap generation changes when a binding comes or goes, in any keymap"
      (call-with-fresh-kernel keys-plugins
       (lambda ()
         (let (keymap (new-keymap))
           (defplugin (node-key ctx)
             "Binds a key in a keymap of its own."
             requires: [input-service]
             (keymap-set-in ctx keymap "RET" 'command-a))
           (let (g0 (keymap-generation))
             (activate-plugin! binds-a)
             (let (g1 (keymap-generation))
               (check (= g1 g0) => #f)
               (activate-plugin! node-key)
               (let (g2 (keymap-generation))
                 (check (= g2 g1) => #f)
                 (deactivate-plugin! node-key)
                 (check (= (keymap-generation) g2) => #f)
                 (check (entry-table-ref keymap "RET") => #f))))))))))
