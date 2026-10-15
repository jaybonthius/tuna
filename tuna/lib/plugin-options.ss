;;; Plugin options: the values `(use-plugin PLUGIN key: value ...)` in
;;; init.ss gives a plugin (docs/briefs/2026-10-configuration.md). A plugin
;;; module declares the options its plugin accepts, each with a name, a
;;; default, documentation, and a type, as settings are declared (ADR 9);
;;; loading init.ss checks every option given against that declaration and
;;; collects every problem with its line before anything changes
;;; (tuna/lib/configuration.ss); the start-up and reload code installs a
;;; declaration's options just before it turns the plugin on
;;; (tuna/boot.ss); and the plugin reads them when it is activated, with
;;; plugin-option. A plugin that the kernel restarts reads the same values
;;; again. Program code can override an option, as `tuna --port` does
;;; for the web transport's port; the override beats init.ss.
;;;
;;;   (defplugin (web-transport ctx) "..."
;;;     (let (port (plugin-option web-transport 'port)) ...))
;;;   (defplugin-options web-transport
;;;     (port 0 "The loopback port to listen on; 0 picks a free one."
;;;           (integer-type 0 65535) flag: "--port"))
prelude: :gerbil/core

(import :tuna/kernel)
(export (struct-out option-type option-spec)
        string-type
        boolean-type
        symbol-type
        integer-type
        defplugin-options
        plugin-option-specs
        parse-option-flag-value
        plugin-option-problems
        set-plugin-options!
        plugin-option-values
        override-plugin-option!
        plugin-option-override
        remove-plugin-option-override!
        plugin-option)

;; What values an option accepts, and how its command-line spelling is
;; parsed. The parser returns a candidate value; CHECK validates it.
(defstruct option-type ((description : :string)
                        (check       : :procedure)
                        (parse       : :procedure))
  final: #t)

(def string-type (make-option-type "a string" string? values))
(def boolean-type
  (make-option-type "#t or #f" boolean?
                    (lambda (text)
                      (cond ((equal? text "#t") #t)
                            ((equal? text "#f") #f)
                            (else 'invalid)))))
(def symbol-type (make-option-type "a symbol" symbol? string->symbol))

(def (integer-type (low : :fixnum) (high : :fixnum)) => option-type
  (make-option-type (string-append "a whole number from " (number->string low)
                                   " to " (number->string high))
                    (lambda (v) (and (fixnum? v) (fx<= low v high)))
                    string->number))

;; One option a plugin accepts.
(defstruct option-spec ((name    : :symbol)
                        (default : :t)
                        (doc     : :string)
                        (type    : option-type)
                        (flag    :? :string))
  final: #t)

;; Plugin -> its option specs. Keyed by the plugin value, so a new version
;; of a plugin (its module read again) has its own declaration; weak, so
;; an old version nothing uses any more is collected with its entry.
(def declared-options (make-hash-table-eq weak-keys: #t))

;; Plugin -> the options its declaration in init.ss gives, as
;; (name . value) pairs; absent options take their default.
(def given-options (make-hash-table-eq weak-keys: #t))

;; Plugin name -> process-lifetime overrides, as (name value . why)
;; lists. Reload may read a new plugin value with the same name; the
;; command line must still win. WHY names the override, such as "--port".
(def option-overrides (make-hash-table-eq))

;; A flag is another spelling of the option, not an action handler.
(defrules option-declaration ()
  ((_ (name default doc type))
   (make-option-spec 'name default doc type #f))
  ((_ (name default doc type flag: flag))
   (make-option-spec 'name default doc type flag)))

(defrules defplugin-options ()
  ((_ plugin spec ...)
   (declare-plugin-options! plugin (list (option-declaration spec) ...))))

;; Record SPECS as the options P accepts. A default must have its type.
(def (declare-plugin-options! (p : plugin) (specs : :list)) => :void
  (for-each (lambda ((s : option-spec))
              (unless ((option-type-check (option-spec-type s)) (option-spec-default s))
                (error (string-append (symbol->string (plugin-name p)) " option "
                                      (symbol->string (option-spec-name s)) ": the default must be "
                                      (option-type-description (option-spec-type s))))))
            specs)
  (hash-put! declared-options p specs))

(def (plugin-option-specs (p : plugin)) => :list
  (hash-ref declared-options p []))

;; Parse TEXT with the option's type; a failed parse uses the same type
;; message as a bad value in init.ss, with the flag and plugin as context.
(def (parse-option-flag-value (p : plugin) (spec : option-spec) (text : :string)) => :t
  (let* ((type (option-spec-type spec))
         (outcome (with-catch (lambda (_) '(failed))
                             (lambda () (list 'parsed ((option-type-parse type) text))))))
    (if (and (eq? (car outcome) 'parsed) ((option-type-check type) (cadr outcome)))
      (cadr outcome)
      (error (string-append (or (option-spec-flag spec) "flag") ": "
                            (symbol->string (plugin-name p)) " option "
                            (symbol->string (option-spec-name spec)) " must be "
                            (option-type-description type))))))

;; Every problem with GIVEN, the options a use-plugin form gives P as
;; (name value where) lists, where WHERE is the option's place in init.ss
;; ("init.ss line 6"). Each problem is one line that starts with WHERE.
(def (plugin-option-problems (p : plugin) (given : :list)) => :list
  (let ((specs (plugin-option-specs p))
        (label (symbol->string (plugin-name p))))
    (let loop ((rest given) (seen []) (problems []))
      (match rest
        ([] (reverse problems))
        ([[name value where] . more]
         (let* ((spec (find (lambda ((s : option-spec)) (eq? (option-spec-name s) name)) specs))
                (problem
                 (cond
                  ((memq name seen)
                   (string-append label " option " (symbol->string name) " is given twice"))
                  ((not spec)
                   (string-append label " has no option " (symbol->string name)
                                  (if (null? specs)
                                    "; it takes no options"
                                    (string-append "; its options are "
                                                   (string-join (map (lambda ((s : option-spec))
                                                                       (symbol->string (option-spec-name s)))
                                                                     specs)
                                                                ", ")))))
                  ((not ((option-type-check (option-spec-type spec)) value))
                   (string-append label " option " (symbol->string name) " must be "
                                  (option-type-description (option-spec-type spec))))
                  (else #f))))
           (loop more (cons name seen)
                 (if problem (cons (string-append where ": " problem) problems) problems))))))))

;; Give P the options VALUES, (name . value) pairs already checked; P
;; reads them the next time it is activated.
(def (set-plugin-options! (p : plugin) (values : :list)) => :void
  (if (null? values)
    (hash-remove! given-options p)
    (hash-put! given-options p values)))

;; Every option P declares, in declaration order, as (name . value): the
;; value in GIVEN, (name . value) pairs from init.ss, else the default.
;; Two declarations with equal values give P the same options, whatever
;; their order or whether a default is written out.
(def (plugin-option-values (p : plugin) (given : :list)) => :list
  (map (lambda ((s : option-spec))
         (cons (option-spec-name s)
               (cond
                ((assq (option-spec-name s) given) => cdr)
                (else (option-spec-default s)))))
       (plugin-option-specs p)))

;; Make P's option NAME VALUE whatever init.ss gives; WHY says what
;; overrides it, such as "--port".
(def (override-plugin-option! (p : plugin) (name : :symbol) (value : :t) (why : :string)) => :void
  (option-spec-named p name)
  (hash-put! option-overrides (plugin-name p)
             (cons [name value . why]
                   (filter (lambda (o) (not (eq? (car o) name)))
                           (hash-ref option-overrides (plugin-name p) [])))))

;; Let init.ss decide P's option NAME again.
(def (remove-plugin-option-override! (p : plugin) (name : :symbol)) => :void
  (hash-put! option-overrides (plugin-name p)
             (filter (lambda (o) (not (eq? (car o) name)))
                     (hash-ref option-overrides (plugin-name p) []))))

;; What overrides P's option NAME, such as "--port", or #f.
(def (plugin-option-override (p : plugin) (name : :symbol)) => (Maybe :string)
  (let (found (assq name (hash-ref option-overrides (plugin-name p) [])))
    (and found (cddr found))))

(def (option-spec-named (p : plugin) (name : :symbol)) => option-spec
  (or (find (lambda ((s : option-spec)) (eq? (option-spec-name s) name))
            (plugin-option-specs p))
      (error (string-append (symbol->string (plugin-name p)) " declares no option "
                            (symbol->string name)))))

;; The value of P's option NAME: an override from program code, else the
;; one init.ss gives, else its default.
(def (plugin-option (p : plugin) (name : :symbol)) => :t
  (let (spec (option-spec-named p name))
    (cond
     ((assq name (hash-ref option-overrides (plugin-name p) [])) => cadr)
     ((assq name (hash-ref given-options p [])) => cdr)
     (else (option-spec-default spec)))))
