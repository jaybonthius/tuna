;;; Boot: activate the standard plugin set, restore the session, run the
;;; editor loop until interrupted, then save the session and shut down.
prelude: :gerbil/core

(import :std/os/signal
        :std/os/signal-handler
        :std/sync/channel
        :tuna/version
        :tuna/kernel
        :tuna/services/session
        :tuna/plugins/keys
        :tuna/plugins/web
        :tuna/plugins/echo-area
        :tuna/plugins/help-panel
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/session
        :tuna/plugins/buffers
        :tuna/plugins/autosave
        :tuna/plugins/single-window
        :tuna/plugins/window-commands
        :tuna/plugins/html-renderer
        :tuna/plugins/basic-editing
        :tuna/plugins/minibuffer
        :tuna/plugins/demo)
(export main)

;; Session slots restore in activation order: buffers (autosave) before
;; the windows that show them (single-window).
(def standard-plugins
  [keys-plugin web-transport-plugin settings-plugin echo-area-plugin help-panel-plugin
   session-plugin rope-text-store-plugin buffers-plugin autosave-plugin single-window-plugin
   window-commands-plugin html-renderer-plugin basic-editing-plugin minibuffer-plugin
   demo-plugin])

(def (main . args)
  (match args
    ([] (run 0))
    (["--port" port]
     (let (number (string->number port))
       (if (and (fixnum? number) (<= 1 number 65535))
         (run number)
         (usage))))
    (else (usage))))

(def (usage) => :void
  (let (port (current-error-port))
    (display "usage: tuna [--port PORT]" port)
    (newline port))
  (exit 2))

(def (run (port : :fixnum)) => :void
  (parameterize ((web-transport-listen-port port))
    (for-each activate-plugin! standard-plugins))
  (restore-session)
  (let ((url (web-transport-url))
        (stopped (make-channel)))
    (add-signal-handler! SIGINT (lambda () (channel-close stopped)))
    (add-signal-handler! SIGTERM (lambda () (channel-close stopped)))
    (start-editor-loop!)
    (displayln "Tuna " (tuna-version) " is running. Open " url)
    (force-output)
    (channel-get stopped)
    (stop-editor-loop!)
    (with-catch (lambda (e)
                  (let (port (current-error-port))
                    (display "Saving the session failed: " port)
                    (display (exception-summary e) port)
                    (newline port)))
                save-session)
    (deactivate-all-plugins!)
    (remove-signal-handler! SIGINT)
    (remove-signal-handler! SIGTERM)))
