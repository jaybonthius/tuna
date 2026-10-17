;;; Settings (ADR 9): named values with a default and documentation,
;;; resolved through a chain of scopes. The dynamic layer comes first: it
;;; holds `with-settings` bindings in a Gerbil parameter, so it belongs to
;;; one thread, and a command waiting at a prompt never sees another
;;; command's bindings (Emacs `let` on a special variable). Then come the
;;; scopes plugins add (such as the buffer), then global values, then the
;;; default. Resolution is a startup-tier service.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel)
(export (interface-out Settings)
        settings-service
        (struct-out setting)
        defsetting
        with-settings
        call-with-settings
        setting-value
        context-set-setting!
        context-add-setting-scope!)

(defstruct setting ((name    : :symbol)
                    (default : :t)
                    (doc     : :string))
  final: #t)

;; (defsetting name default "doc")
(defrules defsetting ()
  ((_ name default doc)
   (identifier? #'name)
   (def name (make-setting 'name default doc))))

;; The dynamic layer: (setting . value) pairs, innermost first.
(def current-setting-bindings (make-parameter []))

(def (call-with-settings (bindings : :list) (thunk : :procedure)) => :t
  (parameterize ((current-setting-bindings (append bindings (current-setting-bindings))))
    (thunk)))

;; (with-settings ((setting value) ...) body ...)
(defrules with-settings ()
  ((_ ((s v) ...) body ...)
   (call-with-settings (list (cons s v) ...) (lambda () body ...))))

(interface Settings
  ;; SETTING's value: from DYNAMIC (the dynamic layer), then the scopes,
  ;; best first, then the global value, then the default.
  (resolve (s : setting) (dynamic : :list)) => :t
  ;; Set S's global value for CTX's plugin; owner-tagged, so it reverts
  ;; when the plugin is deactivated.
  (add-global-value! (ctx : context) (s : setting) (value : :t)) => :void
  ;; Add a scope for CTX's plugin: LOOKUP takes a setting and returns a
  ;; (setting . value) pair or #f. Higher PRIORITY scopes are consulted
  ;; first.
  (add-scope! (ctx : context) (name : :symbol) (lookup : :procedure) (priority : :fixnum)) => :void)

(def settings-service
  (new-service 'settings is-Settings? tier: 'startup
               doc: "Resolves settings through the dynamic layer, scopes, and global values."))

(def (setting-value (s : setting)) => :t
  (with-service-provider (provider settings-service Settings) (Settings-resolve provider s (current-setting-bindings))))

(def (context-set-setting! (ctx : context) (s : setting) (value : :t)) => :void
  (:- (with-service-provider (provider settings-service Settings) (Settings-add-global-value! provider ctx s value)) :void))

(def (context-add-setting-scope! (ctx : context)
                                 (name : :symbol)
                                 (lookup : :procedure)
                                 priority: (priority : :fixnum := 0))
  => :void
  (:- (with-service-provider (provider settings-service Settings) (Settings-add-scope! provider ctx name lookup priority)) :void))
