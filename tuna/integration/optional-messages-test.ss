;;; Optional message displays must not become mandatory activation dependencies.
prelude: :gerbil/core
(import (only-in :tuna/boot session-owner restart-plugin!)
        :std/test :std/interface :tuna/kernel
        :tuna/services/commands :tuna/services/buffers :tuna/services/layout
        :tuna/services/session :tuna/services/configuration
        :tuna/plugins/commands :tuna/plugins/keys :tuna/plugins/rope
        :tuna/plugins/settings :tuna/plugins/buffers :tuna/plugins/layout
        :tuna/plugins/session :tuna/plugins/autosave :tuna/plugins/basic-editing
        :tuna/plugins/minibuffer :tuna/plugins/buttons :tuna/plugins/help-buffer
        :tuna/plugins/view-commands :tuna/plugins/reload-config
        :tuna/plugins/html-renderer
        "../test-support/kernel" "../test-support/keys"
        "../test-support/rename-command" "../test-support/swap-commands"
        "../test-support/endless-commands")
(export optional-messages-test)

(defplugin (swap-configuration ctx)
  "Selects the default providers for swap commands in this test configuration."
  (context-set-swap-providers! ctx html-renderer-plugin layout-plugin buffers-plugin))


(defclass silent-configuration () final: #t)
(implement Configuration silent-configuration
  (reload! (lambda (self) "Reloaded.\n"))
  (last-report (lambda (self) "Last report.\n"))
  (evaluate (lambda (self form) (error "This configuration double does not evaluate code")))
  (swap! (lambda (self old new) (restart-plugin! old new))))

(defplugin (configuration-fixture ctx)
  "A configuration provider independent of any message display."
  provides: [configuration-service]
  (context-provide! ctx configuration-service (Configuration (silent-configuration))))

(def silent-plugins
  [commands-plugin keys-plugin rope-text-store-plugin settings-plugin session-plugin
   buffers-plugin layout-plugin autosave-plugin basic-editing-plugin minibuffer-plugin
   buttons-plugin help-buffer-plugin view-commands-plugin configuration-fixture swap-configuration
   reload-config-plugin rename-command-plugin swap-commands-plugin endless-commands-plugin])

(def optional-messages-test
  (test-suite "optional message displays"
    (test-case "commands, prompts, layouts, session clients and doubles run without messages"
      (let (directory (path-expand (string-append "tuna-silent-test-"
                                                  (number->string (random-integer 1000000000)))
                                   (getenv "TMPDIR" "/tmp")))
        (create-directory* directory)
        (try
          (call-with-fresh-kernel []
            (lambda ()
              (parameterize ((session-state-directory directory))
                (for-each activate-plugin! silent-plugins))
              (check (service-provider messages-service) => #f)
              (restore-session)
              (start-editor-loop!)
              (type! "a" "C-c" "r" "n" "o" "t" "e" "s" "RET")
              (call-on-editor-loop
                (lambda ()
                  (check (buffer-name (current-buffer)) => "notes")
                  (check (text-string (current-text)) => "a")
                  (call-command 'push-button)
                  (call-command 'quit-help)
                  (call-command 'show-config-report)
                  (call-command 'reload-config)
                  (call-command 'split-view-right)
                  (check (length (view-list)) => 3)
                  (call-command 'swap-renderer)
                  (call-command 'swap-renderer)
                  (call-command 'swap-layout)
                  (call-command 'swap-layout)
                  (save-session)
                  (check (file-exists? (path-expand "session.ss" directory)) => #t)
                  (check (file-exists? (path-expand "autosave/notes" directory)) => #t)))
              (let (started? #f)
                (call-on-editor-loop
                  (lambda ()
                    (defplugin (loop-observer ctx)
                      "Records when the cooperative endless command starts."
                      requires: [commands-service]
                      (context-add-hook! ctx pre-command-hook 'observe-loop
                        (lambda ()
                          (when (eq? (this-command) 'loop-forever) (set! started? #t)))))
                    (activate-plugin! loop-observer)))
                (type! "C-c" "l")
                (check (wait-until (lambda () started?)) => #t)
                (type! "C-g")
                (call-on-editor-loop
                  (lambda ()
                    (call-command 'quit-help)
                    (check (last-command) => 'quit-help))))))
          (finally (delete-file-or-directory directory #t)))))))
