;;; Start-up from init.ss (docs/briefs/2026-10-configuration.md): find the
;;; configuration, load it on a worker thread with a time limit, turn its
;;; plugins on one by one so that a failure costs only that plugin and
;;; whatever needs it, and report what happened. This is the program's
;;; start-up code, outside the kernel; it uses only the kernel's public
;;; activation and service queries. It never creates or edits the user's
;;; configuration; only `tuna init` (init-configuration!) writes one, when
;;; asked.
prelude: :gerbil/core

(import (only-in :gerbil/expander import-module)
        (only-in :gerbil/runtime/thread spawn-thread)
        :std/misc/ports
        :std/source
        :tuna/kernel
        :tuna/lib/configuration)
(export (struct-out config-choice report-entry startup-report)
        find-configuration
        default-config-path
        startup-log-path
        load-time-limit
        activation-time-limit
        load-configuration
        activate-configuration!
        start-from-configuration
        check-configuration
        startup-report-text
        write-startup-report!
        starter-configuration
        init-configuration!)

;;; Finding init.ss

;; The configuration to use, and what chose it.
(defstruct config-choice ((path   : :string)     ; absolute
                          (origin : :string))    ; "--config", "TUNA_CONFIG", or "the default location"
  final: #t)

;; The first of: FLAG (from --config), $TUNA_CONFIG, and
;; $XDG_CONFIG_HOME/tuna/init.ss. A path chosen by the flag or the
;; variable is used even if it is missing, so a typo is reported rather
;; than silently replaced by another file.
(def (find-configuration (flag :? :string)) => config-choice
  (let (variable (getenv "TUNA_CONFIG" ""))
    (cond
     (flag (make-config-choice (path-expand flag) "--config"))
     ((not (string-empty? variable)) (make-config-choice (path-expand variable) "TUNA_CONFIG"))
     (else (make-config-choice (default-config-path) "the default location")))))

;; $XDG_<VARIABLE>, or HOME/FALLBACK when it is unset or relative, which
;; the XDG specification ignores.
(def (xdg-directory (variable : :string) (fallback : :string)) => :string
  (let (value (getenv variable ""))
    (if (string-prefix? "/" value)
      value
      (path-expand fallback (getenv "HOME" "/")))))

(def (default-config-path) => :string
  (path-expand "tuna/init.ss" (xdg-directory "XDG_CONFIG_HOME" ".config")))

;; The start-up report's log file, replaced on every start.
(def (startup-log-path) => :string
  (path-expand "tuna/startup.log" (xdg-directory "XDG_STATE_HOME" ".local/state")))

;;; Time limits

;; Seconds a load of init.ss, and each plugin's activation, may take.
(def load-time-limit (make-parameter 10.))
(def activation-time-limit (make-parameter 5.))

;; Seconds a stopped activation gets to undo its partial work.
(def stop-grace 1.)

;; Run THUNK on a new thread for at most SECONDS. Returns (ok . value),
;; (raised . exception), or (timed-out . stopped?). On time-out, with
;; INTERRUPT? the thread is first interrupted with an exception, so that
;; whatever it is doing can undo itself on the way out (an activation rolls
;; back its receipt); a thread that does not stop within stop-grace, or any
;; thread without INTERRUPT?, is terminated, and stopped? tells which.
(def (call-with-time-limit (seconds : :real) (thunk : :procedure)
                           interrupt?: (interrupt? : :boolean := #t))
  => :pair
  (let* ((stop (cons 'time-limit seconds))
         (pending (cons 'pending #f))
         (worker (spawn-thread (lambda ()
                                 (with-catch (lambda (e) (cons 'raised e))
                                             (lambda () (cons 'ok (thunk)))))
                               'tuna-start-up))
         (result (thread-join! worker seconds pending)))
    (cond
     ((not (eq? result pending)) result)
     ((not interrupt?)
      (thread-terminate! worker)
      (cons 'timed-out #t))
     (else
      ;; thread-interrupt! waits for the target, so a helper sends it.
      (spawn-thread (lambda () (thread-interrupt! worker (lambda () (raise stop))))
                    'tuna-start-up-stop)
      (let (late (thread-join! worker stop-grace pending))
        (cond
         ((eq? late pending)
          (thread-terminate! worker)
          (cons 'timed-out #f))
         ((and (eq? (car late) 'raised) (eq? (cdr late) stop))
          (cons 'timed-out #t))
         (else late)))))))

;;; Loading

;; The expander turns init.ss into something runnable; the executable
;; links it (+1.7 MB) and loads it here, once, on first use (about 80 ms).
;; Imports of Tuna's modules need their .ssi files, which `gerbil build`
;; puts in lib/ beside the bin/ holding the executable.
(def (prepare-expander!) => :void
  (gerbil-load-expander!)
  (let (lib (path-expand "../lib" (path-directory (executable-path))))
    (when (and (file-exists? lib)
               (not (member (path-strip-trailing-directory-separator lib)
                            (map path-strip-trailing-directory-separator (load-path)))))
      (add-load-path! lib))))

;; Load the init.ss at PATH (absolute) and return its configuration, or a
;; string saying why it could not be loaded. Loading changes nothing in
;; the editor. It always reloads, so neither an earlier load of the same
;; file nor one that was stopped part-way leaves anything behind; the
;; configuration language defines no module-level names, so each load
;; yields new plugin values and leaves the ones already running intact.
(def (load-configuration (path : :string)) => :t
  (prepare-expander!)
  (let (limit (load-time-limit))
    (match (call-with-time-limit
            limit
            (lambda () (collect-configuration (lambda () (import-module path #t #t))))
            interrupt?: #f)
      (['ok . loaded] loaded)
      (['raised . e] (string-append "Loading " path " failed:\n" (load-failure-text path e)))
      (['timed-out . _]
       (string-append "Loading " path " did not finish within "
                      (seconds-text limit) " and was stopped. Look for a loop in the file.")))))

;; Why loading the file at PATH raised E. The expander's message names the
;; file, line, and column of a syntax error; a reader error, such as an
;; unbalanced parenthesis, gets the line of the innermost unfinished form.
(def (load-failure-text (path : :string) (e : :t)) => :string
  (if (datum-parsing-exception? e)
    (let (position (datum-parsing-exception-filepos e))
      (string-append path ":" (number->string (fx1+ (##filepos-line position)))
                     ":" (number->string (fx1+ (##filepos-col position))) ": "
                     (exception-text e)))
    (exception-text e)))

;; E as the expander displays it, without the backtrace. The expander
;; writes a syntax error's form to the current output port, so that is
;; captured too.
(def (exception-text (e : :t)) => :string
  (let (text (parameterize ((dump-stack-trace? #f))
               (call-with-output-string
                ""
                (lambda (port)
                  (parameterize ((current-output-port port))
                    (display-exception e port))))))
    (string-join (filter (lambda ((line : :string))
                           (not (andmap char-whitespace? (string->list line))))
                         (string-split text #\newline))
                 "\n")))

(def (seconds-text (seconds : :real)) => :string
  (string-append (number->string seconds) " seconds"))

;;; Activation

;; One line of the start-up report.
(defstruct report-entry ((what   : :string)       ; the plugin or block
                         (source :? :string)      ; where init.ss declares it
                         (status : :symbol)       ; on, failed, or skipped
                         (detail : :string))      ; why it failed or was skipped
  final: #t)

;; Turn on CONFIG's plugins and report each: the declared plugins in
;; order, each as soon as the services it requires are provided, each with
;; its config: block right after it, and then the user's own code. A
;; plugin that fails is rolled back and the rest carry on; a plugin whose
;; required services nothing provides is skipped. Every activation has a
;; time limit, since no quit key exists before the input plugin is on.
(def (activate-configuration! (config : configuration)) => :list
  (let* ((declarations (configuration-declarations config))
         (entries [])
         (add! (lambda ((entry : report-entry)) (set! entries (cons entry entries)))))
    (when (ormap declaration-block declarations)
      (let (follower (new-config-block-follower declarations))
        (add! (activate-entry follower (symbol->string (plugin-name follower)) #f))))
    (let loop ((pending declarations))
      (let (ready (find (lambda ((d : declaration)) (null? (missing-services (declaration-target d))))
                        pending))
        (if ready
          (let* ((p (declaration-target ready))
                 (entry (activate-entry p (symbol->string (plugin-name p)) (declaration-source ready))))
            (add! entry)
            (when (and (eq? (report-entry-status entry) 'on) (declaration-block ready))
              (add! (activate-entry (declaration-block ready)
                                    (string-append "config: block of " (symbol->string (plugin-name p)))
                                    (declaration-source ready))))
            (loop (filter (lambda (d) (not (eq? d ready))) pending)))
          (for-each (lambda ((d : declaration))
                      (add! (make-report-entry (symbol->string (plugin-name (declaration-target d)))
                                               (declaration-source d)
                                               'skipped
                                               (string-append "needs "
                                                              (string-join (map (lambda ((svc : service))
                                                                                  (symbol->string (service-name svc)))
                                                                                (missing-services (declaration-target d)))
                                                                           ", ")
                                                              ", which no plugin provides"))))
                    pending))))
    (let (user-code (configuration-user-code config))
      (add! (activate-entry user-code "your own code (plugin init)" #f)))
    (reverse entries)))

;; The services P requires that no plugin provides.
(def (missing-services (p : plugin)) => :list
  (filter (lambda ((svc : service)) (not (service-provider svc)))
          (plugin-requires p)))

;; Activate P within the time limit and describe the outcome.
(def (activate-entry (p : plugin) (what : :string) (source :? :string)) => report-entry
  (let (limit (activation-time-limit))
    (match (call-with-time-limit limit (lambda () (activate-plugin! p)))
      (['ok . _] (make-report-entry what source 'on ""))
      (['raised . e] (make-report-entry what source 'failed (exception-summary e)))
      (['timed-out . stopped?]
       ;; A stopped activation has turned P off; one that could not be
       ;; stopped left P wanted, so turn it off before anything retries it.
       (unless stopped?
         (with-catch void (lambda () (deactivate-plugin! p))))
       (make-report-entry what source 'failed
                          (string-append "did not finish turning on within " (seconds-text limit)
                                         (if stopped?
                                           " and was rolled back"
                                           " and could not be stopped; what it did so far may remain")))))))

;;; Start-up

;; The outcome of a start: the configuration used, why nothing was turned
;; on (PROBLEM) if that is what happened, and one entry per plugin.
(defstruct startup-report ((choice  : config-choice)
                           (problem :? :string)
                           (entries : :list))
  final: #t)

;; Find, load, and activate. Nothing here ends the program: whatever
;; fails is reported, and the rest of Tuna keeps running.
(def (start-from-configuration (choice : config-choice)) => startup-report
  (let (path (config-choice-path choice))
    (if (not (file-exists? path))
      (make-startup-report choice (missing-configuration-text choice) [])
      (let (loaded (load-configuration path))
        (if (configuration? loaded)
          (make-startup-report choice #f (activate-configuration! loaded))
          (make-startup-report choice (string-append loaded "\nNothing was turned on.") []))))))

;; `tuna check`: load CHOICE's file without turning anything on. Returns
;; the problem, or #f when the file loads and its declarations are valid.
(def (check-configuration (choice : config-choice)) => (Maybe :string)
  (let (path (config-choice-path choice))
    (if (not (file-exists? path))
      (missing-configuration-text choice)
      (let (loaded (load-configuration path))
        (and (string? loaded) loaded)))))

(def (missing-configuration-text (choice : config-choice)) => :string
  (string-append
   "No configuration at " (config-choice-path choice)
   " (" (config-choice-origin choice) "), so nothing is turned on.\n"
   "To get one, run `tuna init`, which copies Tuna's starter configuration to "
   (default-config-path) ", or copy starter/init.ss from the Tuna repository yourself."))

(def (startup-report-text (report : startup-report)) => :string
  (let* ((choice (startup-report-choice report))
         (entries (startup-report-entries report))
         (count (lambda ((status : :symbol))
                  (length (filter (lambda ((e : report-entry)) (eq? (report-entry-status e) status))
                                  entries)))))
    (string-append
     "Tuna start-up report\n"
     "Configuration: " (config-choice-path choice) " (" (config-choice-origin choice) ")\n"
     (cond
      ((startup-report-problem report) => (cut string-append <> "\n"))
      (else
       (string-append
        (apply string-append
               (map (lambda ((e : report-entry))
                      (string-append "  " (symbol->string (report-entry-status e))
                                     (make-string (- 9 (string-length (symbol->string (report-entry-status e)))) #\space)
                                     (report-entry-what e)
                                     (if (report-entry-source e)
                                       (string-append " (" (path-strip-directory (report-entry-source e)) ")")
                                       "")
                                     (if (string-empty? (report-entry-detail e))
                                       ""
                                       (string-append ": " (report-entry-detail e)))
                                     "\n"))
                    entries))
        (number->string (count 'on)) " on, " (number->string (count 'failed)) " failed, "
        (number->string (count 'skipped)) " skipped.\n"))))))

;; Write TEXT to the start-up log at PATH, replacing the last start's.
;; Nothing reads it back.
(def (write-startup-report! (text : :string) (path : :string)) => :void
  (create-directory* (path-directory path))
  (write-file-string path text))

;;; tuna init

;; starter/init.ss, built into the executable.
(def starter-configuration
  (utf8->string (this-source-content "../starter/init.ss")))

;; Copy the starter configuration to the default location, unless a file
;; is already there. Returns whether it wrote, and what to tell the user.
(def (init-configuration!) => :pair
  (let (path (default-config-path))
    (if (file-exists? path)
      (cons #f (string-append path " already exists; tuna init leaves it alone."))
      (begin
        (create-directory* (path-directory path))
        (write-file-string path starter-configuration)
        (cons #t (string-append "Wrote Tuna's starter configuration to " path "."))))))
