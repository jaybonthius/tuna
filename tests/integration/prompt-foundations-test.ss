;;; Foundations through real tasks, including both buffers providers.
prelude: :gerbil/core
(import :tuna/plugins/commands/contract
        :std/test :std/error :std/interface :tuna/kernel
        :tuna/plugins/keys/contract :tuna/plugins/buffers/contract :tuna/plugins/minibuffer/contract
        :tuna/plugins/settings/contract :tuna/plugins/layout/contract :tuna/plugins/session/contract
        :tuna/plugins/commands/plugin :tuna/plugins/keys/plugin :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin :tuna/plugins/buffers/plugin :tuna/plugins/layout/plugin
        :tuna/plugins/basic-editing/plugin :tuna/plugins/minibuffer/plugin :tuna/plugins/session/plugin
        "../../plugins/buffers/tests/support/toy-buffers" "../../tuna/tests/support/kernel"
        "../../plugins/keys/tests/support/keys" "../../tuna/tests/support/string-input")
(export prompt-foundations-test)

(def results [])
(def handle #f)
(def identity-before #f)

(defplugin (questions ctx)
  "History reads, a customizable prompt, and a yield-point edit."
  requires: [commands-service input-service minibuffer-service buffers-service]
  (defcommand (history-question) "Ask with a named history."
    (set! results (cons (read-string "History: " history: 'names) results)))
  (keymap-set "C-c h" 'history-question)
  (defcommand (custom-question) "Customize one prompt through its handle."
    (set! results
          (cons
           (read-from-minibuffer "Checked: " history: 'custom
             setup: (lambda ((p : Prompt))
                      (set! handle p)
                      (let (root (buffer-root (prompt-buffer p)))
                        (set-node-children! root
                          (append (node-children root)
                                  [(new-node 'minibuffer-prompt attributes: [['content . "extra"]])])))
                      (keymap-set-in ctx (prompt-keymap p) "C-c v" 'value-answer)
                      (prompt-set-exit-check! p
                        (lambda ((input : :string))
                          (and (not (equal? input "ok")) "Type ok first")))))
           results)))
  (defcommand (value-answer) "Return a non-text value from the prompt."
    (prompt-exit! handle 42 history-text: "chosen"))
  (keymap-set "C-c c" 'custom-question)
  (defcommand (wait-and-edit) "Re-read the live text after a prompt yield point."
    (let* ((t (current-text))
           (snapshot (text-string t))
           (revision (text-chars-revision t))
           (identity [(this-command) (last-command)])
           (answer (read-string "Suffix: ")))
      (set! identity-before identity)
      (set! results
            [snapshot (text-string t) (not (fx= revision (text-chars-revision t)))
             (this-command) (last-command) (key-event-key (last-command-event))])
      ;; Do not use the old point or length: another task edited the text.
      (text-replace! t (fx1+ (text-size t)) (fx1+ (text-size t)) answer)))
  (keymap-set "C-c a" 'wait-and-edit))

(def (on-editor (thunk : :procedure)) => :t (call-on-editor-loop thunk))
(def (prompt-state) => :t
  (on-editor
   (lambda ()
     (let (p (active-prompt))
       (and p (text-string (text-node-content (prompt-display-answer p))))))))

(def (run-prompts (directory : :string) (provider : plugin) (thunk : :procedure)) => :t
  (set! results [])
  (set! handle #f)
  (call-with-fresh-kernel []
    (lambda ()
      (parameterize ((session-state-directory directory))
        (for-each activate-plugin!
          [commands keys test-messages rope-text-store
           settings session provider layout basic-editing
           minibuffer questions]))
      (restore-session)
      (start-editor-loop!)
      (thunk))))

(def (with-temporary-state (thunk : :procedure)) => :t
  (let (directory (path-expand (string-append "tuna-prompt-test-" (number->string (next-id!))) "/tmp"))
    (create-directory* directory)
    (unwind-protect (thunk directory) (delete-file-or-directory directory #t))))

(def prompt-foundations-test
  (test-suite "prompt foundations"
    (test-case "a prompt handle keeps its answer node while an inner prompt is active"
      (with-temporary-state
        (lambda (directory)
          (run-prompts directory buffers
            (lambda ()
              (type! "C-c" "c" "o")
              (let* ((outer (on-editor (lambda () handle)))
                     (answer (on-editor (lambda () (prompt-answer-node outer)))))
                (type! "C-c" "c" "i")
                (on-editor
                  (lambda ()
                    (check (eq? (prompt-answer-node outer) answer) => #t)
                    (check (text-string (text-node-content answer)) => "o")
                    (check (text-string (text-node-content (prompt-answer-node handle))) => "i")
                    (check (eq? (prompt-answer-node handle)
                                (prompt-display-answer (active-prompt))) => #t)
                    (check (eq? answer (prompt-answer-node handle)) => #f)))
                (type! "C-g")
                (check (prompt-state) => "o")
                (type! "C-g")
                (check (on-editor active-prompt) => #f)))))))
    (test-case "an invalid history length fails before a prompt buffer is added"
      (with-temporary-state
       (lambda (directory)
         (run-prompts directory buffers
          (lambda ()
            (on-editor
             (lambda ()
               (with-settings ((minibuffer-history-length -1))
                 (check-exception (read-string "Invalid: " history: 'names) Error?))
               (check (active-prompt) => #f)
               (check (filter (lambda (b) (string-prefix? " *Minibuf-" (buffer-name b)))
                              (buffer-list))
                      => [(get-buffer " *Minibuf-0*")]))))))))
    (test-case "named history deduplicates, navigates back to the draft, and persists across restart"
      (with-temporary-state
       (lambda (directory)
         (run-prompts directory buffers
          (lambda ()
            (type! "C-c" "h" "a" "RET" "C-c" "h" "b" "RET" "C-c" "h" "a" "RET")
            (check (prompt-state) => #f)
            (check (on-editor (lambda () (minibuffer-history 'names))) => ["a" "b"])
            (type! "C-c" "h" "d" "M-p")
            (check (prompt-state) => "a")
            (type! "M-p")
            (check (prompt-state) => "b")
            (type! "M-n" "M-n")
            (check (prompt-state) => "d")
            (type! "C-g")
            (check (prompt-state) => #f)
            (check (on-editor (lambda () (minibuffer-history 'names))) => ["a" "b"])
            (on-editor save-session)))
         (run-prompts directory buffers
          (lambda ()
            (type! "C-c" "h" "M-p")
            (check (prompt-state) => "a")
            (type! "RET")
            (check (prompt-state) => #f)
            (check results => ["a"])
            (on-editor
             (lambda ()
               (with-settings ((minibuffer-history-length 1))
                 (check (minibuffer-history 'names) => ["a"]))
               (with-settings ((minibuffer-history-length 0))
                 (check (minibuffer-history 'names) => []))
               (with-settings ((minibuffer-history-length #f))
                 (check (minibuffer-history 'names) => ["a" "b"])))))))))

    (test-case "the typed handle adds nodes and bindings, refuses RET, and returns a non-text value"
      (with-temporary-state
       (lambda (directory)
         (run-prompts directory buffers
          (lambda ()
            (type! "C-c" "c" "RET")
            (check (prompt-state) => "")
            (check (on-editor current-message) => "Type ok first")
            (check (on-editor (lambda () (minibuffer-history 'custom))) => [])
            (check (on-editor (lambda () (length (node-children (buffer-root (prompt-buffer handle)))))) => 3)
            (type! "o" "k" "C-c" "v")
            (check (prompt-state) => #f)
            (check results => [42])
            (check (on-editor (lambda () (minibuffer-history 'custom))) => ["chosen"])
            (on-editor (lambda () (check-exception (prompt-exit! handle 43) Error?))))))))

    (test-case "ADR 3: text changes during a prompt; the command re-reads state and retains its activation"
      (for-each
       (lambda (provider)
         (with-temporary-state
          (lambda (directory)
            (run-prompts directory provider
             (lambda ()
               (type! "x" "C-c" "a" "!")
               (check (prompt-state) => "!")
               (on-editor
                (lambda ()
                  (select-view (find (lambda (v) (equal? (buffer-name (view-showing v)) "*scratch*"))
                                     (view-list)))))
               (type! "y")
               (check (prompt-state) => "!")
               (on-editor
                (lambda ()
                  (select-view (find (lambda (v) (and (minibuffer-view? v)
                                                      (pair? (node-children (buffer-root (view-showing v))))))
                                     (view-list)))))
               (type! "RET")
               (check (prompt-state) => #f)
               (check results => ["x" "xy" #t 'wait-and-edit 'self-insert-command "a"])
               (check identity-before => ['wait-and-edit 'self-insert-command])
               (check (on-editor (lambda () (text-string (current-text)))) => "xy!")
               (check (on-editor last-command) => 'wait-and-edit))))))
       [buffers toy-buffers]))))
