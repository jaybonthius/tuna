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
        (only-in :gerbil/runtime/syntax
                 SyntaxError? SyntaxError-message SyntaxError-irritants __AST-source __AST->datum)
        (only-in :gerbil/runtime/thread spawn-thread)
        :std/misc/ports
        :std/source
        :tuna/kernel
        :tuna/lib/configuration
        :tuna/plugins/config-blocks)
(export (struct-out config-choice report-entry startup-report)
        parse-command-line
        find-configuration
        default-config-path
        startup-log-path
        load-time-limit
        activation-time-limit
        stop-grace
        load-configuration
        activate-configuration!
        start-from-configuration
        check-configuration
        startup-report-text
        write-startup-report!
        starter-configuration
        init-configuration!)

;;; The command line

;; What ARGS ask for: (run PORT CONFIG), (check CONFIG), or (init), where
;; PORT is 0 for any free port and CONFIG is the --config path or #f; #f
;; when ARGS are not valid.
(def (parse-command-line (args : :list)) => :t
  (match args
    (["init"] '(init))
    (["check" . options]
     (let (parsed (parse-options options #f))
       (and parsed (list 'check (cdr parsed)))))
    (else
     (let (parsed (parse-options args #t))
       (and parsed (list 'run (car parsed) (cdr parsed)))))))

;; OPTIONS as (port . config), or #f when they are not valid; --port is
;; accepted only when PORT? is true.
(def (parse-options (options : :list) (port? : :boolean)) => (Maybe :pair)
  (let loop ((rest options) (port 0) (config #f))
    (match rest
      ([] (cons port config))
      (["--config" path . more] (loop more port path))
      (["--port" value . more]
       (let (number (string->number value))
         (and port? (fixnum? number) (<= 1 number 65535)
              (loop more number config))))
      (else #f))))

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

;; Seconds an activation asked to stop gets before start-up says it is
;; waiting for it.
(def stop-grace (make-parameter 1.))

;; Run THUNK on a new thread; the thread's result is (ok . value) or
;; (raised . exception).
(def (spawn-worker (thunk : :procedure)) => :thread
  (spawn-thread (lambda ()
                  (with-catch (lambda (e) (cons 'raised e))
                              (lambda () (cons 'ok (thunk)))))
                'tuna-start-up))

;; WORKER's result, waiting at most SECONDS (#f: no limit); #f on time-out.
;; An exception that reached no handler, such as a stop request arriving
;; after the worker's own handler returned, becomes (raised . exception).
(def (join-worker (worker : :thread) (seconds :? :real)) => (Maybe :pair)
  (with-catch
   (lambda (e)
     (if (uncaught-exception? e)
       (cons 'raised (uncaught-exception-reason e))
       (raise e)))
   (lambda ()
     (if seconds
       (thread-join! worker seconds #f)
       (thread-join! worker)))))

;; Run THUNK, which loads init.ss, for at most SECONDS; #f when it ran out
;; of time and was terminated. A load changes no kernel state that
;; termination could leave half done (research 01, finding 7); it always
;; reloads, so a module it left stuck is loaded afresh next time.
(def (call-with-load-time-limit (seconds : :real) (thunk : :procedure)) => (Maybe :pair)
  (let* ((worker (spawn-worker thunk))
         (result (join-worker worker seconds)))
    (unless result
      (thread-terminate! worker))
    result))

;; Run ACTIVATE, which turns WHAT on, on a new thread. If it is not done
;; within the activation time limit, interrupt it once with an error,
;; which rolls the activation back like any other failure. Never terminate
;; it: that would skip the kernel's cleanup and leave registrations that
;; no receipt owns (ADR 3 never terminates a thread either). If it has not
;; stopped after stop-grace, say so on stderr at once and wait for it.
(def (call-with-activation-time-limit (what : :string) (activate : :procedure)) => :pair
  (let* ((limit (activation-time-limit))
         (worker (spawn-worker activate)))
    (or (join-worker worker limit)
        (begin
          ;; thread-interrupt! waits for the target, so a helper sends it.
          (spawn-thread
           (lambda ()
             (with-catch void
                         (lambda ()
                           (thread-interrupt!
                            worker
                            (lambda ()
                              (error (string-append "did not finish turning on within "
                                                    (seconds-text limit) " and was stopped")))))))
           'tuna-start-up-stop)
          (or (join-worker worker (stop-grace))
              (begin
                (let (port (current-error-port))
                  (display (string-append what " did not stop when asked after " (seconds-text limit)
                                          "; start-up is waiting for it. Fix init.ss and restart"
                                          " Tuna (Ctrl-C quits).\n")
                           port)
                  (force-output port))
                (: (join-worker worker #f) :pair)))))))

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
;; string saying why it could not be loaded. A file that does not start
;; with `#lang :tuna/config` is not run at all. Loading runs only the
;; file's imports and its use-plugin declarations, which change nothing in
;; the editor; the rest of its code runs when its plugin is turned on.
;; Two things do run at load and must not change the editor: the bodies of
;; the modules it imports, and macro (phase-1) code (tuna/config.ss).
;; Loading always reloads, so neither an earlier load of the same file nor
;; one that was stopped part-way leaves anything behind; the configuration
;; language defines no module-level names, so each load yields new plugin
;; values and leaves the ones already running intact. What the expander
;; prints while loading is discarded; errors are reported instead.
(def (load-configuration (path : :string)) => :t
  (or (language-line-problem path)
      (begin
        (prepare-expander!)
        (let (limit (load-time-limit))
          (match (call-with-load-time-limit
                  limit
                  (lambda ()
                    (collect-configuration
                     (lambda ()
                       (parameterize ((current-output-port (open-output-string)))
                         (import-module path #t #t))))))
            (['ok . loaded] loaded)
            (['raised . e] (string-append "Loading " path " failed:\n" (load-failure-text path e)))
            (#f
             (string-append "Loading " path " did not finish within "
                            (seconds-text limit) " and was stopped. Look for a loop in the file.")))))))

(def language-line "#lang :tuna/config")

;; Why the file at PATH is not a configuration, judged from its first line
;; alone, or #f. Any other language would run the file's code at load.
(def (language-line-problem (path : :string)) => (Maybe :string)
  (let ((first (call-with-input-file path read-line))
        (n (string-length language-line)))
    (and (not (and (string? first)
                   (string-prefix? language-line first)
                   (or (fx= (string-length first) n)
                       (char-whitespace? (string-ref first n)))))
         (string-append "Loading " path " failed:\n" path ":1: the first line must be `"
                        language-line "`, so Tuna did not run the file."))))

;; Why loading the file at PATH raised E, starting with the file, line,
;; and column where known. A reader error, such as an unbalanced
;; parenthesis, gets the line of the innermost unfinished form.
(def (load-failure-text (path : :string) (e : :t)) => :string
  (cond
   ((datum-parsing-exception? e)
    (let (position (datum-parsing-exception-filepos e))
      (string-append path ":" (number->string (fx1+ (##filepos-line position)))
                     ":" (number->string (fx1+ (##filepos-col position))) ": "
                     (exception-text e))))
   ((SyntaxError? e) (syntax-error-text e))
   (else (exception-text e))))

;; A syntax error as one line: where, what, and the offending form.
;; Gerbil's own display of it pretty-prints the form to the console rather
;; than to the port it is given.
(def (syntax-error-text (e : :t)) => :string
  ;; The last located irritant is the most specific: the expander lists
  ;; the form first and the offending part of it after.
  (let* ((irritants (SyntaxError-irritants e))
         (located (find __AST-source (reverse irritants)))
         (shown (or located (and (pair? irritants) (car irritants)))))
    (string-append
     (if located (location-text (__AST-source located)) "")
     (SyntaxError-message e)
     (if shown (string-append ": " (object->string (__AST->datum shown))) ""))))

;; LOCATION, a Gambit source location, as "file:line:column: ".
(def (location-text (location : :t)) => :string
  (let ((container (##locat-container location))
        (position (##locat-start-position location)))
    (string-append (if (string? container) container (object->string container))
                   ":" (number->string (fx1+ (##filepos-line position)))
                   ":" (number->string (fx1+ (##filepos-col position))) ": ")))

;; E as Gerbil displays it, without the backtrace.
(def (exception-text (e : :t)) => :string
  (let (text (parameterize ((dump-stack-trace? #f))
               (call-with-output-string "" (cut display-exception e <>))))
    (string-join (filter (lambda ((line : :string))
                           (not (andmap char-whitespace? (string->list line))))
                         (string-split text #\newline))
                 "\n")))

;; SECONDS for people: "5 s", "0.5 s".
(def (seconds-text (seconds : :real)) => :string
  (string-append
   (if (integer? seconds)
     (number->string (inexact->exact seconds))
     (let (text (number->string (exact->inexact seconds)))
       (if (string-prefix? "." text) (string-append "0" text) text)))
   " s"))

;;; Activation

;; One line of the start-up report.
(defstruct report-entry ((subject : plugin)       ; the plugin, block, or user code
                         (what   : :string)
                         (source :? :string)      ; where init.ss declares it
                         (status : :symbol)       ; on, failed, skipped, or off
                         (detail : :string))      ; why it failed, was skipped, or is off
  final: #t)

;; Turn on CONFIG's plugins and report each: the declared plugins in
;; order, each as soon as the services it requires are provided, each
;; config: block when its plugin comes on (through the config-blocks
;; plugin), and then the user's own code. A plugin that fails is rolled
;; back and the rest carry on; a plugin whose required services nothing
;; provides is skipped. Every activation has a time limit, since no quit
;; key exists before the input plugin is on. Each entry's status is what
;; the kernel says once everything has been turned on, since a later
;; activation can restart or turn off an earlier plugin.
(def (activate-configuration! (config : configuration)) => :list
  (let* ((declarations (configuration-declarations config))
         (follower (and (ormap declaration-block declarations)
                        (new-block-follower declarations)))
         (entries []))                  ; newest first
    ;; Add ENTRY, replacing an earlier entry for the same plugin.
    (def (record! (entry : report-entry))
      (let (same? (lambda ((e : report-entry))
                    (eq? (plugin-name (report-entry-subject e))
                         (plugin-name (report-entry-subject entry)))))
        (set! entries (if (find same? entries)
                        (map (lambda ((e : report-entry)) (if (same? e) entry e)) entries)
                        (cons entry entries)))))
    ;; Activate P, then bring every config: block in line with its plugin.
    (def (activate! (p : plugin) (what : :string) (source :? :string))
      (record! (activate-entry p what source))
      (when follower
        (let drain ()
          (let (pending (take-pending-block-syncs! follower))
            (unless (null? pending)
              (for-each (lambda ((d : declaration)) (record! (sync-block-entry d))) pending)
              (drain))))))
    (when follower
      (let (p (: (block-follower-hooks follower) plugin))
        (activate! p (symbol->string (plugin-name p)) #f)))
    (let loop ((pending declarations))
      (let (ready (find (lambda ((d : declaration)) (null? (missing-services (declaration-target d))))
                        pending))
        (if ready
          (let (p (declaration-target ready))
            (activate! p (symbol->string (plugin-name p)) (declaration-source ready))
            (loop (filter (lambda (d) (not (eq? d ready))) pending)))
          (for-each (lambda ((d : declaration))
                      (let (p (declaration-target d))
                        (record! (make-report-entry
                                  p (symbol->string (plugin-name p)) (declaration-source d) 'skipped
                                  (string-append "needs "
                                                 (string-join (map (lambda ((svc : service))
                                                                     (symbol->string (service-name svc)))
                                                                   (missing-services p))
                                                              ", ")
                                                 ", which no plugin provides")))))
                    pending))))
    (activate! (configuration-user-code config) "your own code (plugin init)" #f)
    (map final-entry (reverse entries))))

;; The services P requires that no plugin provides.
(def (missing-services (p : plugin)) => :list
  (filter (lambda ((svc : service)) (not (service-provider svc)))
          (plugin-requires p)))

;; Activate P within the time limit and describe the outcome by whether
;; it is on.
(def (activate-entry (p : plugin) (what : :string) (source :? :string)) => report-entry
  (let (outcome (call-with-activation-time-limit what (lambda () (activate-plugin! p))))
    (if (plugin-active? p)
      (make-report-entry p what source 'on "")
      (make-report-entry p what source 'failed
                         (match outcome
                           (['raised . e] (exception-summary e))
                           (else "did not come on"))))))

(def (block-label (d : declaration)) => :string
  (string-append "config: block of " (symbol->string (plugin-name (declaration-target d)))))

;; Turn D's block off, then on again if its plugin is on, as the
;; config-blocks plugin does while the editor loop runs.
(def (sync-block-entry (d : declaration)) => report-entry
  (let ((block (: (declaration-block d) plugin))
        (what (block-label d))
        (source (declaration-source d)))
    (with-catch void (lambda () (deactivate-plugin! block)))
    (if (plugin-active? (declaration-target d))
      (activate-entry block what source)
      (make-report-entry block what source 'off "its plugin is off"))))

;; E with its status brought in line with the kernel.
(def (final-entry (e : report-entry)) => report-entry
  (let ((active? (plugin-active? (report-entry-subject e)))
        (status (report-entry-status e)))
    (cond
     ((and (eq? status 'on) (not active?))
      (make-report-entry (report-entry-subject e) (report-entry-what e) (report-entry-source e)
                         'off "was turned off again during start-up"))
     ((and (memq status '(failed off)) active?)
      (make-report-entry (report-entry-subject e) (report-entry-what e) (report-entry-source e)
                         'on ""))
     (else e))))

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
        (number->string (count 'skipped)) " skipped"
        (if (zero? (count 'off)) "" (string-append ", " (number->string (count 'off)) " off"))
        ".\n"))))))

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
