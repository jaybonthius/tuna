;;; The tuna program. `tuna` starts from the user's configuration
;;; (tuna/boot.ss), restores the session, runs the editor loop until
;;; interrupted, then saves the session and shuts down. `tuna check` loads
;;; the configuration without starting anything; `tuna init` copies the
;;; starter configuration to the default location.
prelude: :gerbil/core

(import :std/os/signal
        :std/os/signal-handler
        :std/sync/channel
        :tuna/version
        :tuna/kernel
        :tuna/boot
        :tuna/services/session
        (only-in :tuna/plugins/web web-transport-listen-port web-transport-url)
        ;; Linked into the executable so that init.ss can import them.
        :tuna/config
        :tuna/lib/jobs
        :tuna/lib/timers
        (only-in :tuna/plugins/keys)
        (only-in :tuna/plugins/rope)
        (only-in :tuna/plugins/string-text-store)
        (only-in :tuna/plugins/settings)
        (only-in :tuna/plugins/echo-area)
        (only-in :tuna/plugins/help-panel)
        (only-in :tuna/plugins/buffers)
        (only-in :tuna/plugins/session)
        (only-in :tuna/plugins/autosave)
        (only-in :tuna/plugins/single-window)
        (only-in :tuna/plugins/two-windows)
        (only-in :tuna/plugins/html-renderer)
        (only-in :tuna/plugins/plain-text-renderer)
        (only-in :tuna/plugins/basic-editing)
        (only-in :tuna/plugins/minibuffer)
        (only-in :tuna/plugins/demo)
        (only-in :tuna/plugins/window-commands))
(export main)

(def (main . args)
  (match args
    (["init"]
     (let (outcome (init-configuration!))
       (displayln (cdr outcome))
       (exit (if (car outcome) 0 1))))
    (["check" . options]
     (let (config (parse-options options #f))
       (check config)))
    (else
     (let (port 0)
       (let (config (parse-options args (lambda ((value : :string))
                                          (let (number (string->number value))
                                            (if (and (fixnum? number) (<= 1 number 65535))
                                              (set! port number)
                                              (usage))))))
         (run port config))))))

;; The --config path in OPTIONS, or #f. ON-PORT receives --port's value;
;; without it, --port is not accepted.
(def (parse-options (options : :list) (on-port :? :procedure)) => (Maybe :string)
  (let loop ((rest options) (config #f))
    (match rest
      ([] config)
      (["--config" path . more] (loop more path))
      (["--port" value . more]
       (if on-port
         (begin (on-port value) (loop more config))
         (usage)))
      (else (usage)))))

(def (usage) => :void
  (let (port (current-error-port))
    (display "usage: tuna [--port PORT] [--config PATH]\n       tuna check [--config PATH]\n       tuna init\n"
             port))
  (exit 2))

(def (check (config :? :string)) => :void
  (let (problem (check-configuration (find-configuration config)))
    (if problem
      (begin
        (let (port (current-error-port))
          (display problem port)
          (newline port))
        (exit 1))
      (begin
        (displayln "The configuration loads and its declarations are valid.")
        (exit 0)))))

;; Write the start-up report to stderr and the start-up log.
(def (report-start-up (report : startup-report)) => :void
  (let ((text (startup-report-text report))
        (port (current-error-port)))
    (display text port)
    (force-output port)
    (with-catch (lambda (e)
                  (display "Writing the start-up log failed: " port)
                  (display (exception-summary e) port)
                  (newline port))
                (lambda () (write-startup-report! text (startup-log-path))))))

;; Print a failure of the session plugin's save or restore; Tuna carries on.
(def (call-reporting-session-failure (what : :string) (thunk : :procedure)) => :void
  (when (service-provider session-service)
    (with-catch (lambda (e)
                  (let (port (current-error-port))
                    (display what port)
                    (display " failed: " port)
                    (display (exception-summary e) port)
                    (newline port)))
                thunk)))

(def (run (port : :fixnum) (config :? :string)) => :void
  (report-start-up
   (parameterize ((web-transport-listen-port port))
     (start-from-configuration (find-configuration config))))
  (call-reporting-session-failure "Restoring the session" restore-session)
  (let ((url (web-transport-url))
        (input? (and (service-provider input-service) #t))
        (stopped (make-channel)))
    (add-signal-handler! SIGINT (lambda () (channel-close stopped)))
    (add-signal-handler! SIGTERM (lambda () (channel-close stopped)))
    (when input?
      (start-editor-loop!))
    (displayln "Tuna " (tuna-version) " is running."
               (if url (string-append " Open " url) "")
               (if input? "" " No plugin provides input, so the editor loop is not running."))
    (force-output)
    (channel-get stopped)
    (stop-editor-loop!)
    (call-reporting-session-failure "Saving the session" save-session)
    (deactivate-all-plugins!)
    (remove-signal-handler! SIGINT)
    (remove-signal-handler! SIGTERM)))
