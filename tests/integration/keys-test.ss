(import :tuna/plugins/commands/contract
        :std/error
        :std/test
        :tuna/kernel
        :tuna/plugins/clients/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/settings/contract
        :tuna/plugins/settings/plugin
        "../../tuna/tests/support/kernel"
        "../../tuna/tests/support/redraws"
        (only-in "../../tuna/tests/support/string-input" test-input test-messages current-message))
(export keys-test)

(def (keydown (key : :string) ctrl?: (ctrl? : :boolean := #f) alt?: (alt? : :boolean := #f)
              shift?: (shift? : :boolean := #f) meta?: (meta? : :boolean := #f)
              composing?: (composing? : :boolean := #f) code: (code : :string := "")
              mac?: (mac? : :boolean := #f) left?: (left? : :boolean := #f)
              right?: (right? : :boolean := #f) graph?: (graph? : :boolean := #f)
              client: (from :? client := #f))
  => key-event
  (make-key-event 1 from key code 0 #f composing? alt? ctrl? meta? shift?
                  mac? left? right? graph?))

(def (pointer area part button: (button 1) clicks: (clicks 1) ctrl?: (ctrl? #f)
                 alt?: (alt? #f) shift?: (shift? #f) meta?: (meta? #f) client: (from #f))
  (make-pointer-event 1 from button clicks alt? ctrl? meta? shift?
                      (make-posn area part #f 5)))

(defplugin (binds-a ctx)
  "Binds C-c x to command-a."
  requires: [input-service]
  (keymap-set ctx "C-c x" 'command-a))

(defplugin (binds-b ctx)
  "Binds C-c x to command-b."
  requires: [input-service]
  (keymap-set ctx "C-c  x" 'command-b))

(def (binding keys)
  (let (e (key-binding keys))
    (and e (entry-value e))))

(def keys-plugins
  [test-messages commands keys])

;; The name of the task EVENT resolves to, or #f.
(def (resolve event)
  (let (resolved (Input-resolve! (Input (service-provider input-service)) event))
    (and resolved (car resolved))))

(defplugin (defines-a ctx)
  "Defines command-shared as a."
  requires: [commands-service]
  (define-command ctx (command-shared) "Runs a." 'a))

(defplugin (defines-b ctx)
  "Defines command-shared as b."
  requires: [commands-service]
  (define-command ctx (command-shared) "Runs b." 'b))

;; What the effective command-shared returns when run, or #f.
(def (shared-result)
  (let (c (command-ref 'command-shared))
    (and c ((command-procedure c)))))

(def keys-test
  (test-suite "tuna/plugins/keys"
    (test-case "arrival classifies every modifier path without reading settings"
      (call-with-fresh-kernel [commands keys settings]
        (lambda ()
          (defplugin (no-arrival-settings ctx) "Fails if arrival reads any setting."
            requires: [settings-service]
            (context-add-setting-scope! ctx 'arrival
              (lambda (s) (error "Arrival must not read settings")) priority: 100))
          (activate-plugin! no-arrival-settings)
          (let (input (Input (service-provider input-service)))
            (for-each
             (lambda (event) (check (Input-arrival input event) => 'queue))
             [(keydown "x")
              (keydown "≈" code: "KeyX" alt?: #t mac?: #t left?: #t)
              (keydown "g" code: "KeyG" ctrl?: #t alt?: #t mac?: #t right?: #t)
              (keydown "g" ctrl?: #t alt?: #t graph?: #t)
              (keydown "g" ctrl?: #t alt?: #t)
              (keydown "g" ctrl?: #t meta?: #t)
              (pointer 'view 1)])
            (check (Input-arrival input (keydown "g" ctrl?: #t)) => 'interrupt)))))
    (test-case "optional key queries accept an input provider with no Keys interface"
      (call-with-fresh-kernel [test-input]
        (lambda ()
          (check (part-clickable? 'view) => #f)
          (check (keymap-clickable? (new-keymap) 'view) => #f))))

    (test-case "the same owner's key replaces its previous binding"
      (call-with-fresh-kernel keys-plugins
        (lambda ()
          (let (map (new-keymap))
            (defplugin (repeated-binding ctx) "Two definitions of one key."
              requires: [input-service]
              (keymap-set ctx "C-c x" 'first)
              (keymap-set ctx "C-c x" 'second)
              (keymap-set-in ctx map "C-c x" 'first)
              (keymap-set-in ctx map "C-c x" 'second))
            (activate-plugin! repeated-binding)
            (check (binding "C-c x") => 'second)
            (check (length (entry-table-entries map "C-c x")) => 1)
            (deactivate-plugin! repeated-binding)
            (check (binding "C-c x") => #f)
            (check (entry-table-ref map "C-c x") => #f)))))

    (test-case "where-is orders effective bindings by key count, length and spelling"
      (call-with-fresh-kernel keys-plugins
        (lambda ()
          (let (map (new-keymap))
            (defplugin (reverse-bindings ctx)
              "Reverse lookup and shadows."
              requires: [input-service]
              (keymap-set "C-c a" 'named)
              (keymap-set "z" 'named)
              (keymap-set "x" 'named)
              (keymap-set "M-x" 'named)
              (keymap-set-in map "x" 'other))
            (activate-plugin! reverse-bindings)
            (check (where-is 'named) => ["x" "z" "M-x" "C-c a"])
            (push-input-target! (make-input-target 'reverse map))
            (check (where-is 'named) => ["z" "M-x" "C-c a"])
            (check (where-is 'other) => ["x"])
            (deactivate-plugin! reverse-bindings)
            (check (where-is 'named) => [])))))
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

    (test-case "Mac Option uses each side's live policy and physical US keys"
      (call-with-fresh-kernel [settings keys]
       (lambda ()
         (check (key-description (keydown "≈" code: "KeyX" alt?: #t mac?: #t left?: #t)) => "M-x")
         (check (key-description (keydown "≈" code: "KeyX" alt?: #t mac?: #t right?: #t)) => "≈")
         (check (key-description (keydown "Dead" code: "KeyE" alt?: #t mac?: #t left?: #t)) => "M-e")
         (check (key-description (keydown "ﬁ" code: "Digit5" alt?: #t mac?: #t left?: #t shift?: #t)) => "M-%")
         (check (key-description (keydown "≈" code: "KeyX" alt?: #t mac?: #t left?: #t right?: #t)) => "M-x")
         (check (key-description (keydown "≈" code: "KeyX" alt?: #t mac?: #t)) => "M-x")
         (check (key-description (keydown "y" code: "KeyZ" alt?: #t mac?: #t left?: #t)) => "M-z")
         (check (key-description (keydown "x" code: "KeyX" alt?: #t right?: #t)) => "M-x")
         (check (key-description (keydown "@" code: "KeyQ" alt?: #t ctrl?: #t graph?: #t)) => "@")
         (check (key-description (keydown "Dead" code: "KeyE" alt?: #t mac?: #t left?: #t composing?: #t)) => #f)
         (check (key-description (keydown "Dead" code: "KeyE" alt?: #t mac?: #t right?: #t)) => #f)
         (check (key-description (keydown "Process" code: "KeyE" alt?: #t mac?: #t left?: #t)) => #f)
         (check (key-description (keydown "≈" code: "KeyX" alt?: #t mac?: #t left?: #t ctrl?: #t meta?: #t shift?: #t)) => "C-M-s-X")
         (check (key-description (keydown "ArrowLeft" alt?: #t mac?: #t left?: #t shift?: #t)) => "M-S-<left>")
         (with-settings ((mac-option-modifier 'none) (mac-right-option-modifier 'meta))
           (check (key-description (keydown "≈" code: "KeyX" alt?: #t mac?: #t left?: #t)) => "≈")
           (check (key-description (keydown "≈" code: "KeyX" alt?: #t mac?: #t right?: #t)) => "M-x"))
         (defplugin (option-settings ctx)
           "Changes the Option settings while the input plugin is running."
           requires: [settings-service]
           (context-set-setting! ctx mac-option-modifier 'none)
           (context-set-setting! ctx mac-right-option-modifier 'meta))
         (activate-plugin! option-settings)
         (check (key-description (keydown "≈" code: "KeyX" alt?: #t mac?: #t left?: #t)) => "≈")
         (check (key-description (keydown "≈" code: "KeyX" alt?: #t mac?: #t right?: #t)) => "M-x")
         (deactivate-plugin! option-settings)
         (check (key-description (keydown "≈" code: "KeyX" alt?: #t mac?: #t left?: #t)) => "M-x")
         (with-settings ((mac-option-modifier 'super))
           (check-exception (key-description (keydown "≈" code: "KeyX" alt?: #t mac?: #t left?: #t)) Error?)))))

    (test-case "left Mac Option resolves the M-x binding even without a settings provider"
      (call-with-fresh-kernel keys-plugins
       (lambda ()
         (defplugin (meta-command ctx)
           "A command reached by Meta-x."
           requires: [commands-service input-service]
           (define-command ctx (meta-x) "Runs on M-x." 'ran)
           (keymap-set ctx "M-x" 'meta-x))
         (activate-plugin! meta-command)
         (let (task (Input-resolve! (Input (service-provider input-service))
                                   (keydown "≈" code: "KeyX" alt?: #t mac?: #t left?: #t)))
           (check (car task) => 'meta-x)
           (check ((cdr task)) => 'ran)))))

    (test-case "Mac Meta maps letters, digits and the US punctuation table with Shift"
      (call-with-fresh-kernel [settings]
       (lambda ()
         (for-each
          (lambda (row)
            (let ((code (car row)) (unshifted (cadr row)) (shifted (caddr row)))
              (check (key-description (keydown "Dead" code: code alt?: #t mac?: #t left?: #t))
                     => (string-append "M-" unshifted))
              (check (key-description (keydown "Dead" code: code alt?: #t mac?: #t left?: #t shift?: #t))
                     => (string-append "M-" shifted))))
          '(("KeyA" "a" "A") ("KeyZ" "z" "Z")
            ("Digit0" "0" ")") ("Digit1" "1" "!") ("Digit2" "2" "@")
            ("Digit3" "3" "#") ("Digit4" "4" "$") ("Digit5" "5" "%")
            ("Digit6" "6" "^") ("Digit7" "7" "&") ("Digit8" "8" "*") ("Digit9" "9" "(")
            ("Backquote" "`" "~") ("Minus" "-" "_") ("Equal" "=" "+")
            ("BracketLeft" "[" "{") ("BracketRight" "]" "}") ("Backslash" "\\" "|")
            ("Semicolon" ";" ":") ("Quote" "'" "\"") ("Comma" "," "<")
            ("Period" "." ">") ("Slash" "/" "?"))))))

    (test-case "two plugins binding the same key survive deactivation in either order"
      (call-with-fresh-kernel keys-plugins
       (lambda ()
         (activate-plugin! binds-a)
         (activate-plugin! binds-b)
         (check (binding "C-c x") => 'command-b)
         (deactivate-plugin! binds-a)
         (check (binding "C-c x") => 'command-b)
         (activate-plugin! binds-a)
         (check (binding "C-c x") => 'command-b)
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
         (check (shared-result) => 'b)
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
           requires: [commands-service]
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
         (defplugin (prefix-commands ctx)
           "A command bound under C-c."
           requires: [commands-service input-service]
           (define-command ctx (command-a) "A." (void))
           (keymap-set ctx "C-c x" 'command-a))
         (activate-plugin! prefix-commands)
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

    (test-case "keys in progress are per client: a prefix from one never joins another's keys"
      (call-with-fresh-kernel keys-plugins
       (lambda ()
         (defplugin (client-commands ctx)
           "A command under C-x, and one for printing characters."
           requires: [commands-service input-service]
           (define-command ctx (switch) "C-x b." 'switch)
           (define-command ctx (insert) "A printing character." 'insert)
           (keymap-set ctx "C-x b" 'switch)
           (keymap-set ctx "<printing-char>" 'insert))
         (activate-plugin! client-commands)
         (let ((a (make-client "a"))
               (b (make-client "b")))
           (check (resolve (keydown "x" ctrl?: #t client: a)) => #f)
           (check (resolve (keydown "b" client: b)) => 'insert)
           (check (resolve (keydown "b" client: a)) => 'switch)
           ;; A click ends only its own client's prefix.
           (check (resolve (keydown "x" ctrl?: #t client: a)) => #f)
           (check (resolve (pointer 'view 1 client: b)) => #f)
           (check (resolve (keydown "b" client: a)) => 'switch)
           ;; Events without a client share keys in progress of their own.
           (check (resolve (keydown "x" ctrl?: #t)) => #f)
           (check (resolve (keydown "b" client: a)) => 'insert)
           (check (resolve (keydown "b")) => 'switch)
           ;; A client that went away leaves no prefix behind.
           (check (resolve (keydown "x" ctrl?: #t client: a)) => #f)
           (run-hook client-gone-hook a)
           (check (resolve (keydown "b" client: a)) => 'insert)))))

    (test-case "a command's task sees the client whose event ran it"
      (call-with-fresh-kernel keys-plugins
       (lambda ()
         (defplugin (client-reporters ctx)
           "Commands that report their client and event."
           requires: [commands-service input-service]
           (define-command ctx (report) "Its client and event's client."
             [(current-client) (key-event-client (last-command-event))])
           (define-command ctx (report-scroll) "Its client."
             (current-client))
           (keymap-set ctx "r" 'report)
           (keymap-set ctx scroll-key 'report-scroll))
         (activate-plugin! client-reporters)
         (let* ((a (make-client "a"))
                (input (Input (service-provider input-service)))
                (key-task (Input-resolve! input (keydown "r" client: a)))
                (scroll-task (Input-resolve! input
                                             (make-scroll-event 1 a (make-posn 'view 1 #f 0) 0 #f 0. #f
                                                                #f 0. 0 0 0. 0. 0. 800 600 #t))))
           (check (current-client) => #f)
           (check ((cdr key-task)) => [a a])
           (check ((cdr scroll-task)) => a)))))

    (test-case "the innermost input target's keymap comes first, including for C-g"
      (call-with-fresh-kernel keys-plugins
       (lambda ()
         (defplugin (targets ctx)
           "Commands for the global keymap and two input targets."
           requires: [commands-service input-service]
           (for-each (lambda (name) (context-define-command! ctx name void))
                     '(global-x outer-x inner-x inner-quit))
           (keymap-set ctx "C-c x" 'global-x))
         (activate-plugin! targets)
         (let ((outer (make-input-target 'outer (new-keymap)))
               (inner (make-input-target 'inner (new-keymap))))
           (defplugin (target-keys ctx)
             "Binds keys in the two targets' keymaps."
             requires: [input-service]
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

    (test-case "restarting the command registry re-registers a dependent's commands"
      (call-with-fresh-kernel keys-plugins
       (lambda ()
         (activate-plugin! defines-a)
         (check (shared-result) => 'a)
         (deactivate-plugin! commands)
         (check (plugin-active? defines-a) => #f)
         (activate-plugin! commands)
         (check (plugin-active? defines-a) => #t)
         (check (shared-result) => 'a)
         (let (quit (command-entry 'keyboard-quit))
           (check (entry-owner quit) => 'keys)
           (check (and (string? (entry-source quit))
                       (string-contains (entry-source quit) "plugins/keys/plugin.ss"))
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
           requires: [commands-service input-service]
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
           requires: [commands-service input-service]
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

    (test-case "sources: a binding draws again only what read its keymap"
      (call-with-fresh-kernel keys-plugins
       (lambda ()
         (let ((mine (new-keymap)) (other (new-keymap)))
           (defplugin (binds-mine ctx)
             "Binds a click in a keymap of its own."
             requires: [input-service]
             (keymap-set-in ctx mine "<mouse-1>" 'command-a))
           (check (drawn-again? (lambda () (keymap-clickable? mine 'view)) (lambda () (activate-plugin! binds-mine)))
                  => #t)
           (check (drawn-again? (lambda () (keymap-clickable? mine 'view)) (lambda () (activate-plugin! binds-a)))
                  => #f)
           (check (drawn-again? (lambda () (part-clickable? 'status-line)) (lambda () (deactivate-plugin! binds-a)))
                  => #t)
           (check (drawn-again? (lambda () (keymap-clickable? other 'view)) (lambda () (deactivate-plugin! binds-mine)))
                  => #f)
           (check (drawn-again? (lambda () (keymap-clickable? mine 'view)) (lambda () (activate-plugin! binds-mine)))
                  => #t)))))

    (test-case "a keymap's source changes when a binding comes or goes, and the binding goes with its plugin"
      (call-with-fresh-kernel keys-plugins
       (lambda ()
         (let (keymap (new-keymap))
           (defplugin (node-key ctx)
             "Binds a key in a keymap of its own."
             requires: [input-service]
             (keymap-set-in ctx keymap "RET" 'command-a))
           (let (read (lambda () (keymap-clickable? keymap 'view)))
             (check (drawn-again? read (lambda () (activate-plugin! node-key))) => #t)
             (check (drawn-again? read (lambda () (deactivate-plugin! node-key))) => #t)
             (check (entry-table-ref keymap "RET") => #f))))))))
