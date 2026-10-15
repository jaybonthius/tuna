;;; The tuna program. `tuna` starts from the user's configuration
;;; (tuna/boot.ss), restores the session, runs the editor loop until
;;; interrupted, then saves the session and shuts down; meanwhile it
;;; reloads the configuration when `tuna reload` asks (tuna/control.ss).
;;; `tuna check` loads the configuration without starting anything;
;;; `tuna init` copies the starter configuration to the default location.
prelude: :gerbil/core

(import :std/interface
        :std/log
        :std/os/signal
        :std/os/signal-handler
        :std/sync/channel
        :std/sync/completion
        :tuna/kernel
        :tuna/boot
        :tuna/control
        :tuna/configuration)
(export main)

;; Formatting is process policy, not a plugin's responsibility. The sink
;; writes and flushes each complete record on Gerbil's logger thread.
;; Informational records are shown only from Tuna's own sources ("tuna/..."):
;; libraries such as the HTTP server log their start-up chatter at INFO.
(def (write-log-line (record : Record) (port :~ output-port?)) => :void
  (when (or (fx<= record.level WARN) (string-prefix? "tuna/" record.source))
    (write-shown-log-line record port)))

(def (write-shown-log-line (record : Record) (port :~ output-port?)) => :void
  (unless (fx= record.level INFO)
    (display (log-level->string record.level) port)
    (display " [" port)
    (display record.source port)
    (display "] " port))
  (display record.msg port)
  (when (and (fx<= record.level WARN) (pair? record.data.alist))
    (display " " port)
    (write record.data.alist port))
  (newline port)
  (force-output port))

(defstruct (tuna-stderr-sink BasicLogger) ((port :~ output-port?)) final: #t)

(implement
  (Logger
   (tuna-stderr-sink
    (log (lambda (self record) (write-log-line record self.port)))))
  (LogSink
   (tuna-stderr-sink
    (start! void)
    (stop! (lambda (self) (force-output self.port))))))

(def (main . args)
  (set-default-log-levels! "info")
  (set-system-log-level! INFO)
  ;; Linked modules may have created sources before main set the default.
  (for-each (cut set-source-log-level! <> INFO) (current-log-sources))
  (add-system-sink! (LogSink (tuna-stderr-sink "/tuna/stderr" INFO (current-error-port))))
  (match (parse-command-line args)
    (['init]
     (let (outcome (init-configuration!))
       (displayln (cdr outcome))
       (exit (if (car outcome) 0 1))))
    (['check config flags] (check config flags))
    (['reload] (exit (request-reloads (current-output-port))))
    (['help config _]
     (display (command-line-help (find-configuration config)))
     (exit 0))
    (['run config flags] (run config flags))
    (else (usage))))

(def (usage (choice : config-choice := (find-configuration #f))) => :void
  (display (command-line-help choice) (current-error-port))
  (exit 2))

(def (check (config :? :string) (flags : :list)) => :void
  (let (problem (check-configuration (find-configuration config) flags))
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

;; Run Tuna: start, then handle events on this thread until stopped. The
;; editor loop runs once a plugin provides input. A `tuna reload` request
;; reloads on the editor loop's baton when the loop runs; otherwise this
;; thread, the only one changing plugins then, reloads, and starts the
;; loop if input is now provided (brief, walkthrough step 4).
(def (run (config :? :string) (flags : :list)) => :void
  (let* ((choice (find-configuration config))
         (report (with-catch
                  (lambda (e)
                    (display (string-append (exception-summary e) "\n") (current-error-port))
                    (usage choice))
                  (lambda () (start-from-configuration choice flags)))))
    (report-start-up report)
    (run-hook configuration-report-ready-hook
              (make-configuration-report
               (startup-report-text report) (startup-report-problem report)
               (map (lambda ((entry : report-entry))
                      [(report-entry-status entry) (report-entry-what entry)])
                    (startup-report-entries report))
               (startup-log-path))))
  (let* ((events (make-channel))           ; 'stop, or [reload: completion]
         (control (start-control-server-reporting
                   (lambda ()
                     (if (editor-loop-running?)
                       (call-on-editor-loop reload-outcome)
                       (let (done (make-completion))
                         (channel-put events [reload: done])
                         (completion-wait! done)))))))
    ;; A second Ctrl-C quits at once, without saving the session, for
    ;; when the first cannot be acted on (a reload waiting for a plugin).
    (add-signal-handler! SIGINT
                         (let (interrupts 0)
                           (lambda ()
                             (set! interrupts (fx1+ interrupts))
                             (if (fx= interrupts 1)
                               (channel-put events 'stop)
                               (begin
                                 (display "Ctrl-C again: quitting without saving the session.\n"
                                          (current-error-port))
                                 (exit 130))))))
    (add-signal-handler! SIGTERM (lambda () (channel-put events 'stop)))
    (start-editor-loop-when-input! #t)
    (let loop ()
      (match (channel-get events)
        ('stop (void))
        ([reload: done]
         ;; The loop starts before the answer goes out, so the next
         ;; request already finds it running and reloads on its baton.
         (let (outcome (with-catch (lambda (e)
                                     (cons #f (string-append "The reload failed: "
                                                             (exception-summary e) "\n")))
                                   reload-outcome))
           (start-editor-loop-when-input! #f)
           (completion-post! done outcome))
         (loop))))
    (when control
      (stop-control-server! control
                            (lambda ()
                              (match (channel-try-get events)
                                ([reload: done]
                                 (completion-post! done (cons #f "Tuna is shutting down; nothing was reloaded.\n")))
                                (else (void))))))
    (stop-editor-loop!)
    (run-hook configuration-stopping-hook)
    (deactivate-all-plugins!)
    (remove-signal-handler! SIGINT)
    (remove-signal-handler! SIGTERM)))

;; Reload and return (succeeded? . report-text). The caller holds the baton.
(def (reload-outcome) => :pair
  (let (report (reload-configuration!))
    (cons (reload-succeeded? report) (reload-report-text report))))

;; Start the editor loop if it is not running and a plugin provides
;; input. When ANNOUNCE?, say why the loop cannot start. Plugins announce
;; their own connections; the program knows only whether input is provided.
(def (start-editor-loop-when-input! (announce? : :boolean)) => :void
  (let* ((input? (and (service-provider input-service) #t))
         (start? (and input? (not (editor-loop-running?)))))
    (when start?
      (start-editor-loop!))
    (when (and announce? (not input?))
      (display "No plugin provides input, so the editor loop is not running.\n"
               (current-error-port))
      (force-output (current-error-port)))))

;; Listen for `tuna reload`; on failure say why on stderr and carry on
;; without it, returning #f.
(def (start-control-server-reporting (reload! : :procedure)) => :t
  (with-catch (lambda (e)
                (let (port (current-error-port))
                  (display "tuna reload will not reach this Tuna: " port)
                  (display (exception-summary e) port)
                  (newline port))
                #f)
              (lambda () (start-control-server! reload!))))
