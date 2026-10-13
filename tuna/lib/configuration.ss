;;; What loading init.ss yields: the declared plugins, each with its
;;; optional config: block, and the user's own code as one more plugin
;;; (docs/briefs/2026-10-configuration.md, ADR 2). Loading only collects
;;; these values; the plugins change the editor only once they are turned
;;; on, so receipts undo every effect. The language users write this in is
;;; :tuna/config; the start-up code that loads and activates it is
;;; tuna/boot.ss, and the plugin that keeps config: blocks with their
;;; plugins is tuna/plugins/config-blocks.ss.
prelude: :gerbil/core

(import :tuna/kernel)
(export (struct-out declaration configuration)
        declare-plugin!
        declare-user-code!
        collect-configuration)

;; One use-plugin form: the plugin it declares (target), its config:
;; block as a plugin of its own, and where the form is ("file:line").
(defstruct declaration ((target : plugin)
                        (block  :? plugin)
                        (source :? :string))
  final: #t)

;; A loaded init.ss: its declarations in order, and the plugin holding the
;; rest of its code, which is activated last.
(defstruct configuration ((declarations : :list)
                          (user-code    : plugin))
  final: #t)

;; What one load has collected so far.
(defclass collector ((declarations : :list)    ; newest first
                     (user-code    :? plugin))
  final: #t)

;; The collector of the load in progress, or #f.
(def current-collector (make-parameter #f))

(def (loading-collector (form : :string)) => collector
  (or (current-collector)
      (error (string-append form " works only at the top level of init.ss, while Tuna loads it"))))

;; Record a use-plugin form. VALUE must be a plugin; a plugin declared
;; twice is an error that names both forms.
(def (declare-plugin! (value : :t) (block :? plugin) (source :? :string)) => :void
  (using (c (loading-collector "use-plugin") : collector)
    (let* ((p (with-catch (lambda (_)
                            (error (string-append (or source "init.ss")
                                                  ": use-plugin needs a plugin, not")
                                   value))
                          (lambda () (: value plugin))))
           (earlier (find (lambda ((d : declaration))
                            (eq? (plugin-name (declaration-target d)) (plugin-name p)))
                          c.declarations)))
      (when earlier
        (error (string-append (or source "init.ss") ": plugin "
                              (symbol->string (plugin-name p)) " is already declared at "
                              (or (declaration-source earlier) "an earlier use-plugin"))))
      (set! c.declarations (cons (make-declaration p block source) c.declarations)))))

;; Record the plugin holding the user's own code. The configuration
;; language emits exactly one call, after the declarations.
(def (declare-user-code! (p : plugin)) => :void
  (using (c (loading-collector "The user-code plugin") : collector)
    (set! c.user-code p)))

;; Call LOAD, which loads one init.ss, and return what it declared. LOAD
;; runs in the calling thread; the declarations it makes elsewhere do not
;; count.
(def (collect-configuration (load : :procedure)) => configuration
  (let (c (collector declarations: [] user-code: #f))
    (parameterize ((current-collector c))
      (load))
    (using (c : collector)
      (unless c.user-code
        (error "The file declared nothing: does it start with #lang :tuna/config?"))
      (for-each check-not-reserved! c.declarations)
      (make-configuration (reverse c.declarations) c.user-code))))

;; Plugins are known by name, so a declared plugin must not take a name the
;; configuration itself uses.
(def (check-not-reserved! (d : declaration)) => :void
  (let (name (plugin-name (declaration-target d)))
    (when (memq name '(init config-blocks))
      (error (string-append (or (declaration-source d) "init.ss") ": the plugin name "
                            (symbol->string name) " is reserved for the configuration itself")))))
