;;; What loading init.ss yields: the declared plugins, each with its
;;; optional config: block, and the user's own code as one more plugin
;;; (docs/briefs/2026-10-configuration.md, ADR 2). Loading only collects
;;; these values; nothing touches the editor until a plugin is turned on,
;;; so receipts undo every effect. The language users write this in is
;;; :tuna/config; the start-up code that loads and activates it is
;;; tuna/boot.ss.
prelude: :gerbil/core

(import :tuna/kernel)
(export (struct-out declaration configuration)
        declare-plugin!
        declare-user-code!
        collect-configuration
        new-config-block-follower)

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
      (make-configuration (reverse c.declarations) c.user-code))))

;;; config: blocks follow their plugins

;; A plugin that keeps each config: block of DECLARATIONS on exactly while
;; its plugin is on, while the editor loop runs: when the plugin turns on,
;; its block turns on after it; when it turns off, so does its block, which
;; turns on again if the plugin was only restarted. Lifecycle callbacks may
;; not turn plugins on or off, so each change is queued as a task. Before
;; the loop runs, the start-up code activates blocks itself.
(def (new-config-block-follower (declarations : :list)) => plugin
  (let (blocks (filter declaration-block declarations))
    (defplugin config-blocks
      "Keeps each config: block of init.ss on while its plugin is on."
      (let (ctx (current-context))
        (context-add-hook! ctx plugin-activated-hook 'config-blocks
                           (lambda ((p : plugin))
                             (for-each (lambda ((d : declaration))
                                         (unless (plugin-active? (declaration-block d))
                                           (queue-block-sync! d)))
                                       (declarations-of blocks p))))
        (context-add-hook! ctx plugin-deactivated-hook 'config-blocks
                           (lambda ((p : plugin))
                             (for-each queue-block-sync! (declarations-of blocks p))))))
    config-blocks))

(def (declarations-of (declarations : :list) (p : plugin)) => :list
  (filter (lambda ((d : declaration)) (eq? (plugin-name (declaration-target d)) (plugin-name p)))
          declarations))

(def (queue-block-sync! (d : declaration)) => :void
  (when (editor-loop-running?)
    (spawn-task! 'config-block (lambda () (sync-block! d)))
    (void)))

;; Turn D's block off, then on again if its plugin is on.
(def (sync-block! (d : declaration)) => :void
  (let ((parent (declaration-target d))
        (block (: (declaration-block d) plugin)))
    (deactivate-plugin! block)
    (when (plugin-active? parent)
      (with-catch (lambda (e)
                    (message (string-append "The config: block of "
                                            (symbol->string (plugin-name parent))
                                            (if (declaration-source d)
                                              (string-append " (" (declaration-source d) ")")
                                              "")
                                            " failed and is off: " (exception-summary e))))
                  (lambda () (activate-plugin! block))))))
