;;; What loading init.ss yields: the declared plugins, each with its
;;; optional config: block, and the user's own code as one more plugin
;;; (docs/briefs/2026-10-configuration.md, ADR 2). Loading only collects
;;; these values; the plugins change the editor only once they are turned
;;; on, so receipts undo every effect. The language users write this in is
;;; :tuna/config; the start-up code that loads and activates it is
;;; tuna/boot.ss, and the plugin that keeps config: blocks with their
;;; plugins is tuna/plugins/config-blocks.ss.
prelude: :gerbil/core

(import :tuna/kernel
        :tuna/lib/plugin-options)
(export (struct-out declaration configuration configuration-problems)
        declare-plugin!
        declare-user-code!
        collect-configuration)

;; One use-plugin form: the plugin it declares (target), its config:
;; block as a plugin of its own with the block's code as written
;; (block-forms, which a reload compares), where the form is
;; ("file:line"), and the options it gives the plugin, checked, as
;; (name . value) pairs (tuna/lib/plugin-options.ss).
(defstruct declaration ((target      : plugin)
                        (block       :? plugin)
                        (block-forms : :list)
                        (source      :? :string)
                        (options     : :list))
  final: #t)

;; A loaded init.ss: its declarations in order, and the plugin holding the
;; rest of its code, which is activated last, with that code as written.
(defstruct configuration ((declarations : :list)
                          (user-code    : plugin)
                          (user-forms   : :list))
  final: #t)

;; What a load raises when declarations or options have problems: one
;; line per problem.
(defstruct configuration-problems ((text : :string))
  final: #t)

;; What one load has collected so far: the declarations, the user's code,
;; and every problem with a declaration or an option, each one line
;; starting with where it is in init.ss.
(defclass collector ((declarations : :list)    ; newest first
                     (user-code    :? plugin)
                     (user-forms   : :list)
                     (problems     : :list))   ; newest first
  final: #t)

;; The collector of the load in progress, or #f.
(def current-collector (make-parameter #f))

(def (loading-collector (form : :string)) => collector
  (or (current-collector)
      (error (string-append form " works only at the top level of init.ss, while Tuna loads it"))))

;; Plugins are known by name, so a declared plugin must not take a name the
;; configuration itself uses.
(def reserved-names '(init config-blocks config-service))

;; Record a use-plugin form. FORMS is BLOCK's code as written, [] without
;; a block. OPTIONS are the options the form gives, as (name value where)
;; lists. Problems are collected, not raised, and the load fails with all
;; of them once the whole file has been read: VALUE is not a plugin, the
;; plugin is already declared, its name is reserved, or an option is bad.
(def (declare-plugin! (value : :t) (block :? plugin) (forms : :list) (source :? :string)
                      (options : :list))
  => :void
  (using (c (loading-collector "use-plugin") : collector)
    (let (where (place-text source))
      (def (problem! (text : :string))
        (set! c.problems (cons (string-append where ": " text) c.problems)))
      ;; The kernel exports the plugin type but no predicate; the cast checks.
      (if (not (with-catch (lambda (_) #f) (lambda () (: value plugin) #t)))
        (problem! (string-append "use-plugin needs a plugin, not " (object->string value)))
        (let* ((p (: value plugin))
               (name (symbol->string (plugin-name p)))
               (earlier (find (lambda ((d : declaration))
                                (eq? (plugin-name (declaration-target d)) (plugin-name p)))
                              c.declarations)))
          (cond
           (earlier
            (problem! (string-append "plugin " name " is already declared at "
                                     (place-text (declaration-source earlier)))))
           ((memq (plugin-name p) reserved-names)
            (problem! (string-append "the plugin name " name
                                     " is reserved for the configuration itself")))
           (else
            (let (problems (plugin-option-problems
                            p (map (lambda (o) [(car o) (cadr o) (place-text (caddr o))]) options)))
              (set! c.problems (append (reverse problems) c.problems))
              (set! c.declarations
                (cons (make-declaration p block forms source
                                        (map (lambda (o) (cons (car o) (cadr o))) options))
                      c.declarations))))))))))

;; SOURCE, "file:line" or #f, as "init.ss line 6".
(def (place-text (source :? :string)) => :string
  (if (not source)
    "init.ss"
    (let loop ((i (fx1- (string-length source))))
      (cond
       ((fx< i 0) source)
       ((char=? (string-ref source i) #\:)
        (string-append (path-strip-directory (substring source 0 i))
                       " line " (substring source (fx1+ i) (string-length source))))
       (else (loop (fx1- i)))))))

;; Record the plugin holding the user's own code, and that code as
;; written. The configuration language emits exactly one call, after the
;; declarations.
(def (declare-user-code! (p : plugin) (forms : :list)) => :void
  (using (c (loading-collector "The user-code plugin") : collector)
    (set! c.user-code p)
    (set! c.user-forms forms)))

;; Call LOAD, which loads one init.ss, and return what it declared. LOAD
;; runs in the calling thread; the declarations it makes elsewhere do not
;; count. A file whose declarations or options have problems fails with
;; every one of them, one per line.
(def (collect-configuration (load : :procedure)) => configuration
  (let (c (collector declarations: [] user-code: #f user-forms: [] problems: []))
    (parameterize ((current-collector c))
      (load))
    (using (c : collector)
      (unless c.user-code
        (error "The file declared nothing: does it start with #lang :tuna/config?"))
      (unless (null? c.problems)
        (raise (make-configuration-problems (string-join (reverse c.problems) "\n"))))
      (make-configuration (reverse c.declarations) c.user-code c.user-forms))))
