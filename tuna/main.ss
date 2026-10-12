;;; Boot: activate the standard plugin set, run the editor loop until
;;; interrupted, then shut down.
prelude: :gerbil/core

(import :std/os/signal
        :std/os/signal-handler
        :std/sync/channel
        :tuna/version
        :tuna/kernel
        :tuna/plugins/keys
        :tuna/plugins/web
        :tuna/plugins/echo-area
        :tuna/plugins/help-panel
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/buffers
        :tuna/plugins/html-renderer
        :tuna/plugins/basic-editing
        :tuna/plugins/minibuffer
        :tuna/plugins/demo)
(export main)

(def standard-plugins
  [keys-plugin web-transport-plugin settings-plugin echo-area-plugin help-panel-plugin
   rope-text-store-plugin buffers-plugin html-renderer-plugin basic-editing-plugin
   minibuffer-plugin demo-plugin])

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
  (displayln "usage: tuna [--port PORT]" (current-error-port))
  (exit 2))

(def (run (port : :fixnum)) => :void
  (parameterize ((web-transport-listen-port port))
    (for-each activate-plugin! standard-plugins))
  (let ((url (web-transport-url))
        (stopped (make-channel)))
    (add-signal-handler! SIGINT (lambda () (channel-close stopped)))
    (add-signal-handler! SIGTERM (lambda () (channel-close stopped)))
    (start-editor-loop!)
    (displayln "Tuna " (tuna-version) " is running. Open " url)
    (force-output)
    (channel-get stopped)
    (stop-editor-loop!)
    (deactivate-all-plugins!)
    (remove-signal-handler! SIGINT)
    (remove-signal-handler! SIGTERM)))
