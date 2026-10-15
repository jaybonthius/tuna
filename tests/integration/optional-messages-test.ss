;;; Optional message displays must not become mandatory activation dependencies.
prelude: :gerbil/core
(import (only-in :tuna/boot session-owner restart-plugin!)
        :std/test :std/interface :tuna/kernel
        :tuna/plugins/commands/contract :tuna/plugins/buffers/contract :tuna/plugins/layout/contract
        :tuna/plugins/session/contract :tuna/configuration
        :tuna/plugins/commands/plugin :tuna/plugins/keys/plugin :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin :tuna/plugins/buffers/plugin :tuna/plugins/layout/plugin
        :tuna/plugins/session/plugin :tuna/plugins/autosave/plugin :tuna/plugins/basic-editing/plugin
        :tuna/plugins/minibuffer/plugin :tuna/plugins/buttons/plugin :tuna/plugins/help/plugin
        :tuna/plugins/view-commands/plugin :tuna/plugins/reload-config/plugin
        :tuna/plugins/renderer/plugin
        "../../tuna/tests/support/kernel" "../../plugins/keys/tests/support/keys"
        "../support/rename-command" "../support/swap-commands"
        "../support/endless-commands")
(export optional-messages-test)

(defplugin (swap-configuration ctx)
  "Selects the default providers for swap commands in this test configuration."
  (context-set-swap-providers! ctx html-renderer layout buffers))


(defclass silent-configuration () final: #t)
(implement Configuration silent-configuration
  (set-restart-wrapper! (lambda (self ctx wrapper) (void)))
  (restart (lambda (self owners apply rollback)
             (with-catch (lambda (e) (rollback) (raise e)) apply)))
  (reload! (lambda (self) "Reloaded.\n"))
  (last-report (lambda (self) "Last report.\n"))
  (evaluate (lambda (self form) (error "This configuration double does not evaluate code")))
  (swap! (lambda (self old new) (restart-plugin! old new))))

(defplugin (configuration-fixture ctx)
  "A configuration provider independent of any message display."
  provides: [configuration-service]
  (context-provide! ctx configuration-service (Configuration (silent-configuration))))

(def silent-plugins
  [commands keys rope-text-store settings session
   buffers layout autosave basic-editing minibuffer
   buttons help-buffer view-commands configuration-fixture swap-configuration
   reload-config rename-command swap-commands endless-commands])

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
