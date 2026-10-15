;;; Start-up from init.ss and reload (docs/briefs/2026-10-configuration.md):
;;; find the configuration, load it on a worker thread with a time limit,
;;; compare it with what runs and turn plugins on and off one by one so
;;; that a failure costs only that plugin and whatever needs it, and report
;;; what happened. This is the program's start-up code, outside the
;;; kernel; it uses only the kernel's public activation and service
;;; queries. It never creates or edits the user's configuration; only
;;; `tuna init` (init-configuration!) writes one, when asked.
prelude: :gerbil/core

(import (only-in :std/error deferror-class Error:::init!)
        (only-in :gerbil/expander
                 import-module __module-registry module-context? module-context-path
                 top-context make-top-context top-context-super-set! core-context-root current-expander-context
                 module-context-import import-set? import-set-source module-import?
                 module-import-source module-export-context)
        (only-in :gerbil/runtime/syntax
                 SyntaxError? SyntaxError-message SyntaxError-irritants __AST-source __AST->datum)
        (only-in :gerbil/runtime/thread spawn-thread)
        :std/interface
        :std/misc/ports
        :std/source
        :tuna/kernel
        :tuna/lib/configuration
        :tuna/lib/plugin-options
        (except-in :tuna/configuration activate-plugin!)
        (rename-in :tuna/plugin-use (activate-checked-plugin! activate-plugin!))
        :tuna/config-blocks)
(export (struct-out config-choice report-entry startup-report reload-report)
        parse-command-line
        command-line-help
        find-configuration
        xdg-directory
        default-config-path
        startup-log-path
        load-time-limit
        activation-time-limit
        stop-grace
        seconds-text
        load-configuration
        activate-configuration!
        start-from-configuration
        reload-configuration!
        reload-succeeded?
        reload-report-text
        check-configuration
        startup-report-text
        last-report-text
        write-startup-report!
        starter-configuration
        init-configuration!
        session-owner
        restart-plugin!)

;;; The command line

;; Only program options are understood here. Plugin arguments stay in
;; order until init.ss has told us which plugins declare their flags.
;; Result: (run|check|help CONFIG ARGS), (init), (reload), or #f.
(def (parse-command-line (args : :list)) => :t
  (match args
    (["init"] '(init))
    (["reload"] '(reload))
    ([(or "init" "reload") . _] #f)
    (["check" . options] (parse-program-options options 'check))
    (else (parse-program-options args 'run))))

(def (parse-program-options (args : :list) (command : :symbol)) => :t
  (let loop ((rest args) (config #f) (help? #f) (remaining []))
    (match rest
      ([] (list (if help? 'help command) config (reverse remaining)))
      (["--config" path . more]
       (and (not (string-prefix? "--" path)) (loop more path help? remaining)))
      (["--config"] #f)
      (["--help" . more] (loop more config #t remaining))
      ([arg . more] (loop more config help? (cons arg remaining))))))

;; A configured plugin's command-line spelling and the option it names.
(defstruct plugin-flag ((owner : plugin) (spec : option-spec)) final: #t)

(def (configuration-flags (config : configuration)) => :list
  (let (flags [])
    (for-each
     (lambda ((d : declaration))
       (let (p (declaration-target d))
         (for-each
          (lambda ((spec : option-spec))
            (let (flag (option-spec-flag spec))
              (when flag
                (unless (and (string-prefix? "--" flag) (fx> (string-length flag) 2)
                             (not (string-index flag #\=))
                             (not (ormap char-whitespace? (string->list flag))))
                  (error (string-append (symbol->string (plugin-name p))
                                        " declares an invalid flag: " flag)))
                (when (member flag '("--config" "--help"))
                  (error (string-append "Flag " flag " is claimed by the program and "
                                        (symbol->string (plugin-name p)))))
                (let (other (find (lambda ((f : plugin-flag))
                                   (equal? flag (option-spec-flag (plugin-flag-spec f)))) flags))
                  (when other
                    (error (string-append "Flag " flag " is claimed by both "
                                          (symbol->string (plugin-name (plugin-flag-owner other)))
                                          " and " (symbol->string (plugin-name p))))))
                (set! flags (cons (make-plugin-flag p spec) flags)))))
          (plugin-option-specs p))))
     (configuration-declarations config))
    (reverse flags)))

;; Parse everything before installing any override. A later bad argument
;; must not leave a partly applied command line.
(def (parse-plugin-flags (flags : :list) (args : :list)) => :list
  (let loop ((rest args) (overrides []))
    (match rest
      ([] (reverse overrides))
      ([arg . more]
       (let (flag (find (lambda ((f : plugin-flag))
                         (equal? arg (option-spec-flag (plugin-flag-spec f)))) flags))
         (unless flag (error (string-append "Unknown flag: " arg)))
         (when (or (null? more) (string-prefix? "--" (car more)))
           (error (string-append "Flag " arg " needs a value")))
         (let* ((p (plugin-flag-owner flag))
                (spec (plugin-flag-spec flag))
                (value (parse-option-flag-value p spec (car more))))
           (loop (cdr more) (cons [p (option-spec-name spec) value arg] overrides))))))))

(def usage-text
  "usage: tuna [--config PATH] [PLUGIN FLAGS]\n       tuna check [--config PATH] [PLUGIN FLAGS]\n       tuna init\n       tuna reload\n       tuna --help [--config PATH]\n\n  --config PATH  Load this configuration file.\n  --help         Show this help without activating plugins.\n")

;;; Finding init.ss

;; The configuration to use, and what chose it.
(defstruct config-choice ((path   : :string)     ; absolute
                          (origin : :string))    ; "--config", "TUNA_CONFIG", or "the default location"
  final: #t)

;; Help remains useful with a broken or missing init.ss: program flags
;; plus the load problem, never flags from an invented fallback setup.
(def (command-line-help (choice : config-choice)) => :string
  (let* ((path (config-choice-path choice))
         (loaded (if (file-exists? path) (load-configuration path)
                   (missing-configuration-text choice)))
         (listing
          (with-catch (lambda (e) (string-append "Plugin flags unavailable: " (exception-summary e) "\n"))
            (lambda ()
              (if (string? loaded)
                (string-append "Plugin flags unavailable: " loaded "\n")
                (string-append "Configured plugin flags (" path "):\n"
                  (let (flags (configuration-flags loaded))
                    (if (null? flags) "  (none)\n"
                      (apply string-append
                        (map (lambda ((f : plugin-flag))
                               (let ((spec (plugin-flag-spec f)) (p (plugin-flag-owner f)))
                                 (string-append "  " (option-spec-flag spec) " VALUE  "
                                   (option-spec-doc spec) " (" (symbol->string (plugin-name p)) ")\n")))
                             flags))))))))))
    (string-append usage-text "\n" listing)))

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

;; Seconds an activation asked to stop gets before Tuna says on stderr
;; that it is waiting for it.
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

;; What is changing plugins, for messages: "start-up" or "reload".
(def current-phase (make-parameter "start-up"))

;; Run ACTIVATE, which turns WHAT on, in this thread, so a reload's
;; activations stay on the baton of the task running it. If it is not
;; done within the activation time limit, a watchdog thread interrupts it
;; once with an error, which rolls the activation back like any other
;; failure. Nothing ever terminates it: that would skip the kernel's
;; cleanup and leave registrations that no receipt owns (ADR 3 never
;; terminates a thread either). If it has not stopped after stop-grace,
;; the watchdog says so on stderr at once, and this keeps waiting for it.
;; Returns (ok . value) or (raised . exception).
(def (call-with-activation-time-limit (what : :string) (activate : :procedure)) => :pair
  (let* ((limit (activation-time-limit))
         (target (current-thread))
         ;; Read by the interrupt, which runs in this thread, so a stop
         ;; that arrives after ACTIVATE has returned does nothing.
         (armed? #t)
         (watchdog
          (spawn-thread
           (lambda ()
             (unless (thread-receive limit #f)
               ;; thread-interrupt! may never return once the stop
               ;; escapes into a handler, so a helper sends it.
               (spawn-thread
                (lambda ()
                  (with-catch void
                              (lambda ()
                                (thread-interrupt!
                                 target
                                 (lambda ()
                                   (when armed?
                                     (error (string-append "did not finish turning on within "
                                                           (seconds-text limit) " and was stopped"))))))))
                'tuna-activation-stop)
               (unless (thread-receive (stop-grace) #f)
                 (let (port (current-error-port))
                   (display (string-append what " did not stop when asked after " (seconds-text limit)
                                           "; " (current-phase) " is waiting for it. "
                                           (if (equal? (current-phase) "reload")
                                             "Tuna stays as it is until it stops; to quit, press Ctrl-C twice (the session is not saved)."
                                             "Fix init.ss and restart Tuna (Ctrl-C quits).")
                                           "\n")
                            port)
                   (force-output port)))))
           'tuna-activation-watchdog))
         (outcome (with-catch (lambda (e)
                                (set! armed? #f)
                                (cons 'raised e))
                              (lambda ()
                                (let (value (activate))
                                  (set! armed? #f)
                                  (cons 'ok value))))))
    (thread-send watchdog 'done)
    outcome))

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
;; values and leaves the ones already running intact. The user's own
;; modules that init.ss imports by path are loaded again when they changed
;; (forget-changed-user-modules!). What the expander prints while loading
;; is discarded; errors are reported instead.
(def (load-configuration (path : :string)) => :t
  (car (load-configuration/modules path)))

;; Load as load-configuration does; returns (result . modules-reloaded?),
;; where modules-reloaded? says whether any of the user's own modules
;; changed and were loaded again.
(def (load-configuration/modules (path : :string)) => :pair
  (let (problem (language-line-problem path))
    (if problem
      (cons problem #f)
      (begin
        (prepare-expander!)
        (let* ((reloaded? (forget-changed-user-modules! path))
               (limit (load-time-limit))
               (result
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
                                  (seconds-text limit) " and was stopped. Look for a loop in the file.")))))
          (when (configuration? result)
            ;; Inspect every declaration before activating even the first one.
            ;; Keep failures per plugin so unrelated declarations still start.
            (set! (configuration-plugin-problems result)
              (filter-map
               (lambda ((d : declaration))
                 (let (p (declaration-target d))
                   (with-catch (lambda (e) (cons p (exception-summary e)))
                     (lambda () (check-plugin-declarations! p) #f))))
               (configuration-declarations result))))
          (remember-user-modules!)
          (cons result reloaded?))))))

;;; The user's own modules
;;;
;;; The expander keeps every module it has loaded, so reloading init.ss
;;; alone would keep running the old code of the modules it imports by
;;; path (research 01, finding 4). Before each load, every module loaded
;;; from source whose file changed since it was loaded, and every source
;;; module that imports one, is dropped from the expander's registry, so
;;; the load reads it again and its plugins become new values. Tuna's own
;;; modules and installed packages are compiled (.ssi); they are never
;;; reloaded, so their plugins stay the same objects. Like the registry,
;;; this is per process.

;; Path of each source module the expander has loaded -> its text then.
(def user-module-texts (make-hash-table))

;; The modules in the expander's registry loaded from source (.ss), once
;; each.
(def (source-module-contexts) => :list
  (let (contexts [])
    (hash-for-each (lambda (key value)
                     (when (and (module-context? value)
                                (source-module-path value)
                                (not (memq value contexts)))
                       (set! contexts (cons value contexts))))
                   __module-registry)
    contexts))

;; CONTEXT's file when it was loaded from source, or #f.
(def (source-module-path (context : :t)) => (Maybe :string)
  (let (path (module-context-path context))
    (and (string? path) (string-suffix? ".ss" path) path)))

;; The file at PATH, or #f when it cannot be read.
(def (file-text (path : :string)) => (Maybe :string)
  (with-catch (lambda (_) #f) (lambda () (read-file-string path))))

;; Record the text of each source module loaded since the last call.
(def (remember-user-modules!) => :void
  (for-each (lambda (context)
              (let (path (source-module-path context))
                (unless (hash-key? user-module-texts path)
                  (hash-put! user-module-texts path (file-text path)))))
            (source-module-contexts)))

;; The source modules CONTEXT imports.
(def (imported-source-modules (context : :t)) => :list
  (filter-map (lambda (import)
                (let (imported (cond
                                ((module-context? import) import)
                                ((import-set? import) (import-set-source import))
                                ((module-import? import)
                                 (module-export-context (module-import-source import)))
                                (else #f)))
                  (and imported (source-module-path imported) imported)))
              (module-context-import context)))

;; Drop from the expander's registry every source module other than
;; INIT-PATH whose file changed since it was loaded (one loaded by
;; something else, which remember-user-modules! has not seen, counts as
;; unchanged), and every source
;; module that imports one, directly or not. Returns whether any was
;; dropped.
(def (forget-changed-user-modules! (init-path : :string)) => :boolean
  ;; The expander knows a module by its normalized path: links and ".."
  ;; resolved.
  (let* ((init (if (file-exists? init-path) (path-normalize init-path) init-path))
         (contexts (filter (lambda (context) (not (equal? (source-module-path context) init)))
                           (source-module-contexts)))
         (changed (filter (lambda (context)
                            (let (path (source-module-path context))
                              (and (hash-key? user-module-texts path)
                                   (not (equal? (hash-ref user-module-texts path) (file-text path))))))
                          contexts))
         (stale (let grow ((stale changed))
                  (let (importers (filter (lambda (context)
                                            (and (not (memq context stale))
                                                 (ormap (cut memq <> stale)
                                                        (imported-source-modules context))))
                                          contexts))
                    (if (null? importers) stale (grow (append importers stale)))))))
    (for-each (lambda (key)
                (when (memq (hash-get __module-registry key) stale)
                  (hash-remove! __module-registry key)))
              (hash-keys __module-registry))
    (for-each (lambda (context) (hash-remove! user-module-texts (source-module-path context)))
              stale)
    (pair? stale)))

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
   ((configuration-problems? e) (configuration-problems-text e))
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

;;; Applying a configuration: start-up and reload
;;;
;;; Start-up and reload are one procedure, apply-configuration!: compare
;;; the configuration just loaded with the one running (nothing, at
;;; start-up) and change only the difference, one unit at a time. A unit
;;; is a declared plugin, a config: block, or the user's own code, and is
;;; known by its plugin name, which is how the kernel knows plugins too.

;; One line of a start-up or reload report.
(defstruct report-entry ((subject : plugin)       ; the plugin, block, or user code
                         (what   : :string)
                         (source :? :string)      ; where init.ss declares it
                         ;; on, replaced, restarted, off, failed, skipped, or deferred
                         (status : :symbol)
                         (detail : :string))      ; why, for anything but on and replaced
  final: #t)

;; The configuration Tuna runs: the file it came from; its declarations
;; as running, in file order (a block that a reload left alone keeps the
;; plugin value that is on); the plugin holding the user's own code and
;; that code as written; and the config-blocks plugin, once a
;; configuration has had blocks.
(defstruct running-configuration ((choice       : config-choice)
                                  (declarations : :list)
                                  (user-code    :? plugin)
                                  (user-forms   : :list)
                                  (follower     :? block-follower))
  final: #t)

;; What Tuna runs, or #f before start-up. Start-up sets it and each
;; reload replaces it; like the kernel, it is changed only by whoever
;; holds the baton.
(def current-running #f)

;; How one declaration of the new configuration differs from the running
;; one (OLD, #f when it is new): add, replace, retry (the same plugin or
;; a new version of it, off), block (the same plugin, its block changed), retry-block (both
;; the same, the block off), or keep.
(defstruct change ((kind : :symbol)
                   (new  : declaration)
                   (old  :? declaration))
  final: #t)

(def (declaration-name (d : declaration)) => :symbol
  (plugin-name (declaration-target d)))

(def (named (name : :symbol) (declarations : :list)) => (Maybe declaration)
  (find (lambda ((d : declaration)) (eq? (declaration-name d) name)) declarations))

;; Bring the editor in line with CONFIG, loaded from CHOICE's file, and
;; return the report's lines with the number of units left as they were.
;; MODULES-RELOADED? says whether the load read any of the user's own
;; modules again; blocks and the user's code may use them, so then those
;; are replaced too.
;;
;; By plugin name: a plugin no longer declared is turned off; a new one is
;; turned on; one whose value is another object (its module was reloaded)
;; is replaced; the same object is left alone, or turned on again if it is
;; off. A config: block is replaced when its code as written changed, its
;; plugin is replaced, or modules were reloaded; so is the user's own
;; code. Plugins are turned on in file order, each as soon as the services
;; it requires are provided; a block follows its plugin through the
;; config-blocks plugin; the user's own code comes last.
;;
;; Replacing turns the running unit off and the new one on. If the new one
;; fails it is undone, and the running one, still in memory, is turned
;; back on. While the editor loop runs, a plugin that provides a
;; startup-tier service is neither turned off nor replaced: restart-plugin!
;; checks its closure and reports it as deferred to the next start.
;; Every activation has the time limit of
;; call-with-activation-time-limit.
(defstruct configuration-diff ((choice : config-choice)
                               (config : configuration)
                               (old : running-configuration)
                               (modules-reloaded? : :boolean)
                               (removed : :list)
                               (swaps : :list))
  final: #t)

(defstruct configuration-execution ((declarations : :list)
                                    (kept : :list)
                                    (decided : :list)
                                    (providers-before : :list)
                                    (replaced : :list)
                                    (entries : :list))
  final: #t)

(def (classify-configuration (choice : config-choice) (config : configuration)
                             (modules-reloaded? : :boolean)) => configuration-diff
  (let* ((old (or current-running (make-running-configuration choice [] #f [] #f)))
         (old-declarations (running-configuration-declarations old))
         (new-declarations (configuration-declarations config))
         (swaps (filter-map
                 (lambda ((d : declaration))
                   (and (not (named (declaration-name d) old-declarations))
                        (let (removed (find
                                      (lambda ((o : declaration))
                                        (and (not (named (declaration-name o) new-declarations))
                                             (ormap (lambda ((svc : service))
                                                      (memq svc (plugin-provides (declaration-target o))))
                                                    (plugin-provides (declaration-target d)))))
                                      old-declarations))
                          (and removed (cons d removed))))) new-declarations)))
    (make-configuration-diff choice config old modules-reloaded?
      (filter (lambda ((d : declaration))
                (not (or (named (declaration-name d) new-declarations)
                         (find (lambda (pair) (eq? (cdr pair) d)) swaps))))
              (reverse old-declarations))
      swaps)))

;; Report ordering is stable even when an earlier result is superseded.
(def (record-entry (entries : :list) (entry : report-entry)) => :list
  (let (same? (lambda ((e : report-entry))
                (eq? (plugin-name (report-entry-subject e))
                     (plugin-name (report-entry-subject entry)))))
    (if (find same? entries)
      (map (lambda ((e : report-entry)) (if (same? e) entry e)) entries)
      (cons entry entries))))

(def (apply-configuration! (choice : config-choice) (config : configuration)
                           (modules-reloaded? : :boolean)) => :pair
  (report-configuration
   (execute-configuration! (classify-configuration choice config modules-reloaded?))))

;; Whether D gives its plugin other options than O, the running
;; declaration of the same plugin object: compared by each option's
;; value or default, so reordering options or writing out a default
;; changes nothing. A difference only in options that program code
;; overrides changes nothing now either; it is reported
;; as taking effect at a start without the override.
(def (options-change? (d : declaration) (o : declaration) (record! : :procedure)) => :boolean
  (let* ((p (declaration-target d))
         (new (plugin-option-values p (declaration-options d)))
         (old (plugin-option-values p (declaration-options o)))
         (differing (map car (filter (lambda (n) (not (member n old))) new)))
         (overridden (filter (cut plugin-option-override p <>) differing)))
    (cond
     ((null? differing) #f)
     ((fx= (length overridden) (length differing))
      (record! (make-report-entry
                p (plugin-label p) (declaration-source d) 'deferred
                (string-append (overridden-text p overridden)
                               ", so the change takes effect only when Tuna starts without the override")))
      #f)
     (else #t))))

;; Classify D against the running declarations.
(def (classify-declaration (d : declaration) (diff : configuration-diff)
                           (record! : :procedure)) => change
  (let* ((old-declarations (running-configuration-declarations (configuration-diff-old diff)))
         (swaps (configuration-diff-swaps diff))
         (modules-reloaded? (configuration-diff-modules-reloaded? diff))
         (o (named (declaration-name d) old-declarations)))
    (cond
     ((assq d swaps) => (lambda (pair) (make-change 'replace d (cdr pair))))
     ((not o) (make-change 'add d #f))
     ((not (eq? (declaration-target o) (declaration-target d)))
      (make-change (if (plugin-active? (declaration-target o)) 'replace 'retry) d o))
     (else
      (let* ((same-block? (if (declaration-block d)
                            (and (declaration-block o)
                                 (not modules-reloaded?)
                                 (equal? (declaration-block-forms d) (declaration-block-forms o)))
                            (not (declaration-block o))))
             (kept (if same-block?
                     (make-declaration (declaration-target d) (declaration-block o)
                                       (declaration-block-forms d) (declaration-source d)
                                       (declaration-options d))
                     d)))
        (cond
         ((not (plugin-active? (declaration-target d))) (make-change 'retry kept o))
         ((options-change? d o record!) (make-change 'replace kept o))
         ((not same-block?) (make-change 'block kept o))
         ((and (declaration-block kept) (not (plugin-active? (: (declaration-block kept) plugin))))
          (make-change 'retry-block kept o))
         (else (make-change 'keep kept o))))))))

;; Refine live/off decisions after removals, preserving retry and follower order.
(def (execute-configuration! (diff : configuration-diff)) => configuration-execution
  (let* ((choice (configuration-diff-choice diff))
         (config (configuration-diff-config diff))
         (modules-reloaded? (configuration-diff-modules-reloaded? diff))
         (old (configuration-diff-old diff))
         (old-declarations (running-configuration-declarations old))
         (new-declarations (configuration-declarations config))
         (follower (running-configuration-follower old))
         (working old-declarations)     ; the declarations running now
         (user-code (running-configuration-user-code old))
         (user-forms (running-configuration-user-forms old))
         (kept-units [])                ; units left alone, to check at the end
         ;; Units whose status the reload decided although the kernel,
         ;; which knows plugins only by name, would report it otherwise: a
         ;; failed new version undone, or a turn-off the kernel refused.
         (decided [])
         (providers-before (service-providers))
         (replaced-names [])            ; plugins replaced by a new value
         (entries []))
    (def (record! (entry : report-entry)) => :void
      (set! entries (record-entry entries entry)))
    ;; Make D the running declaration of NAME, or forget NAME when D is #f.
    (def (set-working! (name : :symbol) (d :? declaration))
      (let (others (filter (lambda ((e : declaration)) (not (eq? (declaration-name e) name)))
                           working))
        (set! working (if d (cons d others) others)))
      (when follower
        (follow-declarations! follower working)))
    ;; Bring every block whose plugin changed in line with it. QUIET?
    ;; reports only failures, for blocks that only follow a plugin being
    ;; swapped or restored.
    (def (drain! (quiet? : :boolean))
      (when follower
        (let loop ()
          (let (pending (take-pending-block-syncs! follower))
            (unless (null? pending)
              (for-each (lambda ((d : declaration))
                          (let (entry (sync-block-entry d))
                            (unless (and quiet? (memq (report-entry-status entry) '(on off)))
                              (record! entry))))
                        pending)
              (loop))))))
    ;; Turn D's block, which was turned off, back on; report only a failure.
    (def (restore-block! (d : declaration))
      (drain! #t)
      (when (declaration-block d)
        (let (entry (sync-block-entry d))
          (unless (memq (report-entry-status entry) '(on off))
            (record! entry)))))
    ;; Turn D's block off: #f once it is off (or D has none), otherwise
    ;; why the kernel kept it on.
    (def (turn-off-block! (d : declaration)) => :t
      (let (block (declaration-block d))
        (and block (turn-off! block))))
    (def (decide! (name : :symbol))
      (set! decided (cons name decided)))
    ;; Record that turning off P, or the block of D, was refused, with
    ;; WHY from turn-off! and CONSEQUENCE after the reason.
    (def (record-refusal! (p : plugin) (what : :string) (source :? :string) (why : :t)
                          (consequence : :string))
      (decide! (plugin-name p))
      (match (refusal-outcome why p consequence (not (equal? what (plugin-label p))))
        ([status . detail] (record! (make-report-entry p what source status detail)))))
    ;; A unit whose block the kernel kept on is left as it is.
    (def (block-refused! (d : declaration) (why : :t) (consequence : :string))
      (record-refusal! (: (declaration-block d) plugin) (block-label d) (declaration-source d)
                       why consequence))

    ;; A plugin no longer declared.
    (def (remove! (d : declaration))
      (let* ((p (declaration-target d))
             (what (plugin-label p))
             (source (declaration-source d)))
        (cond
           ((turn-off-block! d)
            => (cut block-refused! d <> ", so turning it off takes effect at next start"))
           (else
            (set-working! (declaration-name d) #f)
            (cond
             ((turn-off! p)
              => (lambda (why)
                   (set-working! (declaration-name d) d)
                   (restore-block! d)
                   (record-refusal! p what source why ", so turning it off takes effect at next start")))
             (else
              (drain! #f)
              (record! (make-report-entry p what source 'off "no longer declared"))))))))

    ;; A plugin declared now that was not before, or the same plugin, off.
    (def (add! (c : change))
      (let* ((d (change-new c))
             (p (declaration-target d)))
        (when (change-old c)
          (turn-off-block! (change-old c)))       ; its plugin is off, so nothing needs it
        (set-working! (declaration-name d) d)
        (set-plugin-options! p (declaration-options d))
        (record! (with-override-note (activate-entry p (plugin-label p) (declaration-source d))
                                     (declaration-options d)))
        (drain! #f)))

    ;; A new value of a running plugin.
    (def (replace! (c : change))
      (let* ((d (change-new c))
             (o (: (change-old c) declaration))
             (p (declaration-target d))
             (running (declaration-target o))
             (what (plugin-label p))
             (source (declaration-source d))
             ;; The same plugin replaced only for its options.
             (consequence (if (eq? p running)
                            ", so the new options take effect at next start"
                            ", so the new version takes effect at next start")))
        (cond
           ((turn-off-block! o)
            => (cut block-refused! o <> consequence))
           (else
            (set-working! (declaration-name d) d)
            (let* ((outcome (call-with-activation-time-limit
                             what (lambda ()
                                    (restart-plugin! running p
                                      prepare: (lambda () (set-plugin-options! p (declaration-options d)))
                                      recover: (lambda ()
                                                 (set-plugin-options! running (declaration-options o))
                                                 (set-plugin-options! p (declaration-options o)))))))
                   (ok? (eq? (car outcome) 'ok)))
              (if ok?
                (begin
                  (set! replaced-names (cons (plugin-name p) replaced-names))
                  (when (not (eq? (declaration-name o) (declaration-name d)))
                    (set-working! (declaration-name o) #f))
                  (record! (with-override-note (make-report-entry p what source 'replaced "")
                                              (declaration-options d))))
                (begin
                  (set-working! (declaration-name d) #f)
                  (set-working! (declaration-name o) o)
                  (decide! (plugin-name p))
                  (record! (make-report-entry p what source
                              (if (StartupRestartRefusal? (cdr outcome)) 'deferred 'failed)
                              (if (StartupRestartRefusal? (cdr outcome))
                                (cdr (refusal-outcome (cdr outcome) running consequence))
                                (string-append (exception-summary (cdr outcome))
                                  (if (plugin-active? running) "; the running version is back on"
                                    (string-append "; turning the running version back on failed too: "
                                                   (exception-summary (cdr outcome))))))))))
              (drain! #f)
              (when (and ok? (declaration-block o) (declaration-block d))
                (let ((name (plugin-name (declaration-block d)))
                      (same? (eq? (declaration-block o) (declaration-block d))))
                  (set! entries
                    (map (lambda ((e : report-entry))
                           (if (and (eq? (plugin-name (report-entry-subject e)) name)
                                    (eq? (report-entry-status e) 'on))
                             (with-status e (if same? 'restarted 'replaced)
                                          (if same? "its plugin was replaced" "")) e)) entries)))))))))

    ;; The same plugin with a changed block, or with its block off.
    (def (replace-block! (c : change))
      (let* ((d (change-new c))
             (o (: (change-old c) declaration))
             (block (declaration-block d))
             (old-block-on? (and (declaration-block o) (plugin-active? (declaration-block o))))
             (why (turn-off-block! o)))
        (unless why
          (set-working! (declaration-name d) d))
        (cond
         (why
          (block-refused! o why ", so the new version takes effect at next start"))
         ((not block)
          (when old-block-on?
            (record! (make-report-entry (: (declaration-block o) plugin) (block-label o)
                                        (declaration-source d) 'off "no longer declared"))))
         (else
          (let (entry (sync-block-entry d))
            (cond
             ((eq? (report-entry-status entry) 'on)
              (record! (if (and (declaration-block o) (eq? (change-kind c) 'block))
                         (with-status entry 'replaced "")
                         entry)))
             ((and (declaration-block o) (eq? (change-kind c) 'block))
              (let (running (make-declaration (declaration-target o) (declaration-block o)
                                              (declaration-block-forms o) (declaration-source d)
                                              (declaration-options o)))
                (set-working! (declaration-name d) running)
                (decide! (plugin-name block))
                (let (back (sync-block-entry running))
                  (record! (with-status entry 'failed
                                        (string-append (report-entry-detail entry)
                                                       (if (eq? (report-entry-status back) 'on)
                                                         "; the running version is back on"
                                                         (string-append "; turning the running version back on failed too: "
                                                                        (report-entry-detail back)))))))))
             (else (record! entry))))))
        (drain! #f)))

    ;; Supply file order before any activation, including blocks. Kept
    ;; owners share this rank with their entries, so a reorder is immediate.
    (let loop ((rest new-declarations) (rank 1))
      (unless (null? rest)
        (let (d (: (car rest) declaration))
          (set-plugin-order! (declaration-target d) rank)
          (when (declaration-block d)
            (set-plugin-order! (declaration-block d) rank)))
        (loop (cdr rest) (fx1+ rank))))
    (set-plugin-order! (configuration-user-code config) (fx1+ (length new-declarations)))
    (unwind-protect
      (begin
        (when follower
          (defer-block-syncs! follower #t))
        (when (and (not follower) (ormap declaration-block new-declarations))
          (set! follower (new-block-follower working))
          (defer-block-syncs! follower #t)
          (let (p (: (block-follower-hooks follower) plugin))
            (record! (activate-entry p (plugin-label p) #f))))
        (for-each remove! (configuration-diff-removed diff))
        (let* ((all-changes (map (lambda ((d : declaration)) (classify-declaration d diff record!)) new-declarations))
               (problems (configuration-plugin-problems config))
               (changes (filter (lambda ((c : change))
                                  (not (assq (declaration-target (change-new c)) problems))) all-changes))
               (pending (filter (lambda ((c : change)) (not (eq? (change-kind c) 'keep))) changes)))
          (for-each
           (lambda ((c : change))
             (let* ((d (change-new c)) (p (declaration-target d))
                    (problem (assq p problems)) (old (change-old c)))
               (when problem
                 (set-working! (declaration-name d) (or old d))
                 (decide! (plugin-name p))
                 (record! (make-report-entry p (plugin-label p) (declaration-source d) 'failed
                            (string-append (cdr problem)
                              (if (and old (plugin-active? (declaration-target old)))
                                "; the running version stays" "")))))))
           all-changes)
          (for-each (lambda ((c : change))
                      (when (eq? (change-kind c) 'keep)
                        (set-working! (declaration-name (change-new c)) (change-new c))
                        (set! kept-units (cons (change-new c) kept-units))))
                    changes)
          (let loop ((pending pending))
            (let (ready (find (lambda ((c : change))
                                (or (memq (change-kind c) '(block retry-block))
                                    (null? (missing-services (declaration-target (change-new c))))))
                              pending))
              (if ready
                (begin
                  (case (change-kind ready)
                    ((add retry) (add! ready))
                    ((replace) (replace! ready))
                    (else (replace-block! ready)))
                  (loop (filter (lambda (c) (not (eq? c ready))) pending)))
                (for-each (lambda ((c : change))
                            (let* ((d (change-new c))
                                   (p (declaration-target d)))
                              (record! (make-report-entry
                                        p (plugin-label p) (declaration-source d) 'skipped
                                        (string-append "needs " (missing-services-text p)
                                                       ", which no plugin provides"
                                                       (if (eq? (change-kind c) 'replace)
                                                         "; the running version stays"
                                                         ""))))))
                          pending)))))
        (let* ((new-code (configuration-user-code config))
               (new-forms (configuration-user-forms config))
               (what "your own code (plugin init)")
               (was-on? (and user-code (plugin-active? user-code))))
          (if (and was-on? (not modules-reloaded?) (equal? user-forms new-forms))
            (set! kept-units (cons user-code kept-units))
            (cond
             ((and was-on? (turn-off! user-code))
              => (lambda (why)
                   (record-refusal! user-code what #f why
                                    ", so the new version takes effect at next start")))
             (else
              (let (entry (activate-entry new-code what #f))
                (cond
                 ((eq? (report-entry-status entry) 'on)
                  (set! user-code new-code)
                  (set! user-forms new-forms)
                  (record! (if was-on? (with-status entry 'replaced "") entry)))
                 (was-on?
                  (decide! 'init)
                  (record! (with-status entry 'failed
                                        (string-append (report-entry-detail entry)
                                                       (restored-text user-code what #f)))))
                 (else
                  (set! user-code new-code)
                  (set! user-forms new-forms)
                  (record! entry)))))))))
      (set! current-running
        (make-running-configuration
         choice
         (append (filter-map (lambda ((d : declaration)) (named (declaration-name d) working))
                             new-declarations)
                 (filter (lambda ((d : declaration)) (not (named (declaration-name d) new-declarations)))
                         working))
         user-code user-forms follower))
      (when follower
        (defer-block-syncs! follower #f)))
    (set! evaluation-module (configuration-module config))
    (make-configuration-execution new-declarations kept-units decided providers-before replaced-names entries)))

;; Reconcile results with the final running state, then format the report.
(def (report-configuration (result : configuration-execution)) => :pair
  (let ((new-declarations (configuration-execution-declarations result))
        (kept-units (configuration-execution-kept result))
        (decided (configuration-execution-decided result))
        (providers-before (configuration-execution-providers-before result))
        (replaced-names (configuration-execution-replaced result))
        (entries (configuration-execution-entries result)))
    (def (record! (entry : report-entry)) => :void
      (set! entries (record-entry entries entry)))
    ;; Units left alone that a change turned off on the way.
    (for-each (lambda (unit)
                (match unit
                  ((? declaration?)
                   (let ((p (declaration-target unit))
                         (block (declaration-block unit)))
                     (cond
                      ((not (plugin-active? p))
                       (record! (make-report-entry p (plugin-label p) (declaration-source unit) 'off
                                                   (turned-off-text p))))
                      ((and block (not (plugin-active? block)))
                       (record! (make-report-entry block (block-label unit) (declaration-source unit)
                                                   'off "was turned off during the reload"))))
                     (match (and (plugin-active? p)
                                 (restarting-services p providers-before replaced-names))
                       ([svc . more]
                        (record! (make-report-entry
                                  p (plugin-label p) (declaration-source unit) 'restarted
                                  (string-append "the kernel restarted it for the new provider of "
                                                 (string-join (map symbol->string (cons svc more)) ", ")))))
                       (else (void)))))
                  (else
                   (unless (plugin-active? unit)
                     (record! (make-report-entry unit "your own code (plugin init)" #f 'off
                                                 (turned-off-text unit)))))))
              kept-units)
    ;; A unit whose failed new version was undone is on again under the
    ;; same name, which is all the kernel knows it by.
    (let* ((final (map (lambda ((e : report-entry))
                         (if (memq (plugin-name (report-entry-subject e)) decided)
                           e
                           (final-entry e)))
                       (reverse entries)))
           (units (append (map declaration-name new-declarations)
                          (filter-map (lambda ((d : declaration))
                                        (let (block (declaration-block d))
                                          (and block (plugin-name block))))
                                      new-declarations)
                          '(init)))
           (reported (map (lambda ((e : report-entry)) (plugin-name (report-entry-subject e))) final)))
      (cons final (length (filter (lambda (name) (not (memq name reported))) units))))))

(def (plugin-label (p : plugin)) => :string
  (symbol->string (plugin-name p)))

(def (with-status (e : report-entry) (status : :symbol) (detail : :string)) => report-entry
  (make-report-entry (report-entry-subject e) (report-entry-what e) (report-entry-source e)
                     status detail))

;; Turn RUNNING, the version that ran before a failed replacement, back
;; on, and say how that went.
(def (restored-text (running : plugin) (what : :string) (source :? :string)) => :string
  (let (entry (activate-entry running what source))
    (if (eq? (report-entry-status entry) 'on)
      "; the running version is back on"
      (string-append "; turning the running version back on failed too: "
                     (report-entry-detail entry)))))

;; "option port is overridden by --port" for P's options NAMES.
(def (overridden-text (p : plugin) (names : :list)) => :string
  (string-join (map (lambda ((name : :symbol))
                      (string-append "option " (symbol->string name) " is overridden by "
                                     (or (plugin-option-override p name) "the program")))
                    names)
               "; "))

;; ENTRY, when it is on or replaced, noting the options in GIVEN that
;; program code overrides.
(def (with-override-note (entry : report-entry) (given : :list)) => report-entry
  (let* ((p (report-entry-subject entry))
         (overridden (filter (cut plugin-option-override p <>) (map car given))))
    (if (and (pair? overridden) (memq (report-entry-status entry) '(on replaced)))
      (with-status entry (report-entry-status entry) (overridden-text p overridden))
      entry)))

;; Each service's name and the name of its provider, or #f.
(def (service-providers) => :list
  (map (lambda ((info : service-info)) (cons (service-info-name info) (service-info-provider info)))
       (describe-services)))

;; The services P requires whose provider changed since BEFORE (from
;; service-providers), or was replaced by a new value (its name in
;; REPLACED): the kernel restarted P for each.
(def (restarting-services (p : plugin) (before : :list) (replaced : :list)) => :list
  (let (infos (describe-services))
    (filter-map
     (lambda ((svc : service))
       (let* ((name (service-name svc))
              (info (find (lambda ((i : service-info)) (eq? (service-info-name i) name)) infos))
              (now (and info (service-info-provider info)))
              (was (cond ((assq name before) => cdr) (else #f))))
         (and now
              (or (not (eq? now was)) (memq now replaced))
              name)))
     (plugin-requires p))))

;; The startup-tier provider in P's restart closure, if the loop runs.
(def (startup-closure (p : plugin)) => (Maybe :pair)
  (and (editor-loop-running?)
       (let* ((names (map plugin-name (plugin-deactivation-closure p)))
              (info (find (lambda ((info : service-info))
                            (and (eq? (service-info-tier info) 'startup)
                                 (memq (service-info-provider info) names)))
                          (describe-services))))
         (and info (cons (service-info-name info) (service-info-provider info))))))

;; One orchestration path, outside the kernel. Callbacks install new options
;; before activation and old options before rollback when a reload needs it.
(def (restart-plugin! (old : plugin) (new :? plugin)
                      prepare: (prepare : :procedure := void)
                      recover: (recover : :procedure := void)) => :void
  (when new (check-plugin-declarations! new))
  (let ((fixed (startup-closure old))
        (closure (plugin-deactivation-closure old)))
    (when fixed (raise (StartupRestartRefusal (car fixed) (cdr fixed))))
    (let ((apply (lambda ()
                   (deactivate-plugin! old)
                   (prepare)
                   (when new
                     (activate-plugin! new)
                     (unless (plugin-active? new) (error "Replacement did not activate" (plugin-name new))))))
          (rollback (lambda ()
                      (when new (deactivate-plugin! new))
                      (recover)
                      (activate-plugin! old)
                      (for-each activate-plugin! (cdr closure)))))
      (call-with-configuration-restart (map plugin-name closure) apply rollback))))

;; Turn P off: #f once it is off, otherwise the refusal or failure.
(def (turn-off! (p : plugin)) => :t
  (let (raised (with-catch (lambda (e) e) (lambda () (restart-plugin! p #f) #f)))
    (and (plugin-active? p) (or raised #t))))

;; How to report that the kernel kept P on (WHY, from turn-off!), as
;; (status . detail). Turning off a plugin that the provider of a
;; startup-tier service needs, or that provides one, waits for the next
;; start: CONSEQUENCE says what waits.
(def (refusal-outcome (why : :t) (p : plugin) (consequence : :string)
                      (code-block? : :boolean := #f)) => :pair
  (match (and (StartupRestartRefusal? why)
              (cons (StartupRestartRefusal-service why) (StartupRestartRefusal-provider why)))
    (#f (cons 'failed (string-append "could not be turned off: "
                                     (if (eq? why #t) "it stayed on" (exception-summary why)))))
    ([service . provider]
     (cons 'deferred
           (string-append (if (eq? provider (plugin-name p))
                            (string-append (if code-block? "it provides the startup-tier service "
                                              "provides the startup-tier service ")
                                           (symbol->string service))
                            (string-append "the provider of the startup-tier service "
                                           (symbol->string service) " (" (symbol->string provider)
                                           ") needs it"))
                          consequence)))))

;; The reload policy has one refusal, distinct from activation failures.
(deferror-class StartupRestartRefusal ((service : :symbol) (provider : :symbol))
  #f
  (lambda (self service provider)
    (Error:::init! self "Restart required for startup service" irritants: [service])
    (set! (StartupRestartRefusal-service self) service)
    (set! (StartupRestartRefusal-provider self) provider)))

;; Why P, which a reload left alone, is off now.
(def (turned-off-text (p : plugin)) => :string
  (if (null? (missing-services p))
    "was turned off during the reload"
    (string-append "needs " (missing-services-text p) ", which no plugin provides")))

;; The services P requires that no plugin provides.
(def (missing-services (p : plugin)) => :list
  (filter (lambda ((svc : service)) (not (service-provider svc)))
          (plugin-requires p)))

(def (missing-services-text (p : plugin)) => :string
  (string-join (map (lambda ((svc : service)) (symbol->string (service-name svc)))
                    (missing-services p))
               ", "))

;; Activate P within the time limit and describe the outcome by whether
;; it is on. Startup-tier policy is checked by restart-plugin! before teardown.
(def (activate-entry (p : plugin) (what : :string) (source :? :string)
                     order: (order :? :fixnum := #f)) => report-entry
  (let (outcome (call-with-activation-time-limit what (lambda () (activate-plugin! p order: order))))
    (cond
     ((plugin-active? p)
      (make-report-entry p what source 'on ""))
     (else
      (make-report-entry p what source 'failed
                         (match outcome
                           (['raised . e] (exception-summary e))
                           (else "did not come on")))))))

(def (block-label (d : declaration)) => :string
  (string-append "config: block of " (symbol->string (declaration-name d))))

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
     ((and (memq status '(on replaced restarted)) (not active?))
      (with-status e 'off (string-append "was turned off again during " (current-phase))))
     ((and (memq status '(failed off)) active?)
      (with-status e 'on ""))
     (else e))))

;; Turn on CONFIG, loaded from CHOICE's file, as at start-up: everything
;; is new. Returns the report's lines.
(def (activate-configuration! (choice : config-choice) (config : configuration)) => :list
  (set! current-running #f)
  (car (apply-configuration! choice config #f)))

;;; Start-up

;; The outcome of a start: the configuration used, why nothing was turned
;; on (PROBLEM) if that is what happened, and one entry per plugin.
(defstruct startup-report ((choice  : config-choice)
                           (problem :? :string)
                           (entries : :list))
  final: #t)

;; Find, load, and activate. Nothing here ends the program: whatever
;; fails is reported, and the rest of Tuna keeps running. The
;; configuration plugin comes on first, so plugins can reach the reload
;; and the report through the configuration service.
(def (start-from-configuration (choice : config-choice) (args : :list := [])) => startup-report
  (let* ((path (config-choice-path choice))
         (loaded (if (file-exists? path) (load-configuration path)
                   (missing-configuration-text choice)))
         (overrides (if (configuration? loaded)
                      (parse-plugin-flags (configuration-flags loaded) args)
                      (if (null? args) []
                        (error (string-append "Cannot validate plugin flags: " loaded))))))
    (for-each (lambda (o) (apply override-plugin-option! o)) overrides)
    (set! current-running (make-running-configuration choice [] #f [] #f))
    (set! evaluation-module (and (configuration? loaded) (configuration-module loaded)))
    (let* ((service-entry (activate-entry session-owner "the configuration service" #f order: (##greatest-fixnum)))
           (service-failure (if (eq? (report-entry-status service-entry) 'on) [] [service-entry]))
           (report (if (configuration? loaded)
                     (make-startup-report choice #f
                                          (append service-failure
                                                  (car (apply-configuration! choice loaded #f))))
                     (make-startup-report choice (string-append loaded "\nNothing was turned on.")
                                          service-failure))))
      (set! last-report-text (startup-report-text report))
      (run-hook configuration-started-hook)
      report)))

;; The text of the last start-up or reload report, or #f before either.
(def last-report-text #f)

;; The start-up owner is never a declaration in the running configuration,
;; so reload cannot diff or restart it. Evaluated bindings last until exit;
;; their parent tracks the latest successfully loaded configuration.
(def evaluation-module #f)

(defclass configuration-provider ((owner : context)
                                  (environment : top-context)
                                  (restart-wrappers : entry-table)) final: #t)

(implement Configuration configuration-provider
  (activate! (lambda (self target order) (activate-plugin! target order: order)))
  (reload! (lambda (self) (reload-report-text (reload-configuration!))))
  ;; Held quits, as for a reload: the calling command may belong to a
  ;; plugin the swap restarts, and its cancellation must not cut the swap
  ;; short; the command quits once the swap is complete.
  (swap! (lambda (self old new) (with-inhibit-quit (restart-plugin! old new))))
  (set-restart-wrapper!
   (lambda (self ctx wrapper)
     (let (old (entry-table-ref self.restart-wrappers 'restart))
       (when old
         (error "Restart wrapper already registered" (entry-owner old) (context-plugin-name ctx)))
       ;; An around-restart callback can register further effects later;
       ;; those belong to its participant, not to the command that swaps.
       (context-add-entry! ctx self.restart-wrappers 'restart (context-bind ctx wrapper))
       (void))))
  (restart (lambda (self owners apply rollback)
             (let (registered (entry-table-ref self.restart-wrappers 'restart))
               (if registered
                 ((entry-value registered) owners apply rollback)
                 (with-catch (lambda (e) (rollback) (raise e)) apply)))))
  (last-report (lambda (self) last-report-text))
  (evaluate (lambda (self form)
              (call-with-context self.owner
                (lambda ()
                  ;; Without a loaded init, keep the root that supplies core syntax.
                  (when evaluation-module
                    (top-context-super-set! self.environment evaluation-module))
                  (parameterize ((current-expander-context self.environment))
                    (eval form)))))))

(defplugin (session-owner ctx)
  "Owns live evaluation, reload init.ss, and configuration reports."
  provides: [configuration-service]
  ;; Interactive customizations win ordinary configuration ties, even after
  ;; declarations are reordered or added by a reload.
  (prepare-expander!)
  ;; The loaded module already resolved relative imports and import filters.
  ;; Its body defines no module bindings; user definitions are inside init.
  ;; The persistent child keeps evaluated definitions and explicit imports;
  ;; evaluate updates its parent when reload replaces the configuration module.
  (let (environment (make-top-context evaluation-module))
    (parameterize ((current-expander-context environment))
      (eval '(import :tuna/config)))
    (context-provide! ctx configuration-service
                      (Configuration (configuration-provider owner: ctx environment: environment
                                                              restart-wrappers: (new-entry-table))))))

;; `tuna check`: load CHOICE's file without turning anything on. Returns
;; the problem, or #f when the file loads and its declarations are valid.
(def (check-configuration (choice : config-choice) (args : :list := [])) => (Maybe :string)
  (let (path (config-choice-path choice))
    (if (not (file-exists? path))
      (missing-configuration-text choice)
      (let (loaded (load-configuration path))
        (if (string? loaded) loaded
          (with-catch exception-summary
            (lambda ()
              (parse-plugin-flags (configuration-flags loaded) args)
              (let (problems (configuration-plugin-problems loaded))
                (and (pair? problems) (string-join (map cdr problems) "\n"))))))))))

(def (missing-configuration-text (choice : config-choice)) => :string
  (string-append
   "No configuration at " (config-choice-path choice)
   " (" (config-choice-origin choice) "), so nothing is turned on.\n"
   "To get one, run `tuna init`, which copies Tuna's starter configuration to "
   (default-config-path) ", or copy starter/init.ss from the Tuna repository yourself."))

;;; Reload

;; The outcome of a reload: the configuration file, why nothing changed
;; (PROBLEM) if the trial load failed, one entry per unit that changed or
;; failed, and how many units were left as they were.
(defstruct reload-report ((choice    : config-choice)
                          (problem   :? :string)
                          (entries   : :list)
                          (unchanged : :fixnum)
                          ;; A quit (C-g) arrived during the reload, which
                          ;; finished first.
                          (quit?     : :boolean))
  final: #t)

;; A user module was read again by a load that then failed, so the next
;; reload that applies must still replace blocks and the user's code.
(def modules-pending? #f)

;; Load the running configuration's file again as a trial and, if it
;; loads, apply the difference (apply-configuration!); a failed load
;; changes nothing. The caller holds the baton: it is a task while the
;; editor loop runs (the reload-config command, or call-on-editor-loop
;; for `tuna reload`), and otherwise the only thread changing plugins.
;; A quit waits until the reload is done, as for any plugin operation
;; (ADR 3); the report is returned anyway, saying a quit arrived, since
;; raising the quit would replace it and nothing is left to stop. A
;; stronger quit (ADR 3's third interrupt) fails the unit it lands in,
;; which is undone like any failure. Nothing is written to disk.
(def (reload-configuration!) => reload-report
  (let (running current-running)
    (unless running
      (error "Tuna did not start from a configuration, so there is nothing to reload"))
    (let* ((choice (running-configuration-choice running))
           (path (config-choice-path choice)))
      (if (not (file-exists? path))
        (remember-report!
         (make-reload-report choice
                             (string-append "No configuration at " path " ("
                                            (config-choice-origin choice) "). Nothing was changed.")
                             [] 0 #f))
        (match (load-configuration/modules path)
          ([(? configuration? loaded) . reloaded?]
           (let* ((applied #f)
                  (quit? (with-catch
                          (lambda (e)
                            (unless (and applied (quit-condition? e))
                              (raise e))
                            #t)
                          (lambda ()
                            (parameterize ((current-phase "reload"))
                              (with-inhibit-quit
                               (set! applied (apply-configuration! choice loaded
                                                                   (or reloaded? modules-pending?)))))
                            #f))))
             (set! modules-pending? #f)
             (remember-report! (make-reload-report choice #f (car applied) (cdr applied) quit?))))
          ([problem . reloaded?]
           (when reloaded?
             (set! modules-pending? #t))
           (remember-report!
            (make-reload-report choice (string-append problem "\nNothing was changed.") [] 0 #f))))))))

(def (remember-report! (report : reload-report)) => reload-report
  (set! last-report-text (reload-report-text report))
  report)

;; Whether the reload loaded and nothing in it failed.
(def (reload-succeeded? (report : reload-report)) => :boolean
  (and (not (reload-report-problem report))
       (not (ormap (lambda ((e : report-entry)) (eq? (report-entry-status e) 'failed))
                   (reload-report-entries report)))))

;;; Reports

(def (startup-report-text (report : startup-report)) => :string
  (report-text "Tuna start-up report" (startup-report-choice report)
               (startup-report-problem report) (startup-report-entries report) #f))

;; A reload report in the start-up report's format.
(def (reload-report-text (report : reload-report)) => :string
  (string-append
   (report-text "Tuna reload report" (reload-report-choice report)
                (reload-report-problem report) (reload-report-entries report)
                (reload-report-unchanged report))
   (if (reload-report-quit? report)
     "C-g was pressed during the reload; the reload finished first.\n"
     "")))

;; TITLE, the configuration, then PROBLEM or one line per entry and the
;; counts; UNCHANGED, when given, counts the units left as they were.
(def (report-text (title : :string) (choice : config-choice) (problem :? :string)
                  (entries : :list) (unchanged :? :fixnum))
  => :string
  (let (count (lambda ((status : :symbol))
                (length (filter (lambda ((e : report-entry)) (eq? (report-entry-status e) status))
                                entries))))
    (string-append
     title "\n"
     "Configuration: " (config-choice-path choice) " (" (config-choice-origin choice) ")\n"
     (if problem
       (string-append problem "\n")
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
        (apply string-append
               (map (lambda ((status : :symbol))
                      (let (n (count status))
                        (if (zero? n)
                          ""
                          (string-append ", " (number->string n) " " (symbol->string status)))))
                    '(replaced restarted off deferred)))
        (if unchanged (string-append ", " (number->string unchanged) " unchanged") "")
        ".\n")))))

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
