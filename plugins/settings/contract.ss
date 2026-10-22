;;; Settings (ADR 9): named values with a default and documentation,
;;; resolved through a chain of scopes. The dynamic layer comes first: it
;;; holds `with-settings` bindings in a Gerbil parameter, so it belongs to
;;; one thread, and a command waiting at a prompt never sees another
;;; command's bindings (Emacs `let` on a special variable). Then come the
;;; scopes plugins add (such as the buffer), then global values, then the
;;; default. Resolution is a startup-tier service.
;;;
;;; Each setting has a source (ADR 17) that changes when its global value
;;; is set or goes, and one more source changes when a scope is added or
;;; goes; resolving a setting records reads of both, and each scope records
;;; what it reads itself (the buffer scope, the buffer's own values).
;;; Drawing resolves settings without the dynamic layer: a screen shows the
;;; editor's settings, not what one command bound for itself.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/lib/memo)
(export (interface-out Settings)
        settings-service
        (struct-out setting)
        defsetting
        with-settings
        call-with-settings
        setting-value
        context-set-setting!
        context-add-setting-scope!
        settings-generation)

(defstruct setting ((name    : :symbol)
                    (default : :t)
                    (doc     : :string))
  final: #t)

;; Setting -> its source, which changes with its global value. A setting
;; is plain data, compared and hashed by its fields, so its source, which
;; changes, is kept beside it; a source does not refer to its setting.
(def setting-sources (make-hash-table test: eq? weak-keys: #t))

;; Changes when a setting made without defsetting is first set.
(def unlisted-settings-source (new-source))

;; A setting named NAME, with its source.
(def (new-setting (name : :symbol) (default : :t) (doc : :string)) => setting
  (let (s (make-setting name default doc))
    (hash-put! setting-sources s (new-source))
    s))

;; (defsetting name default "doc")
(defrules defsetting ()
  ((_ name default doc)
   (identifier? #'name)
   (def name (new-setting 'name default doc))))

;; S's global value changed: change its source, made now if S has none.
(def (setting-changed! (s : setting)) => :void
  (let (source (hash-get setting-sources s))
    (if source
      (source-changed! source)
      (begin
        (hash-put! setting-sources s (new-source))
        (source-changed! unlisted-settings-source)))))

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

;; Changes whenever a scope is added or goes.
(def scopes-source (new-source))

(def (setting-value (s : setting)) => :t
  (record-read! (or (hash-get setting-sources s) unlisted-settings-source))
  (record-read! scopes-source)
  (with-service-provider (provider settings-service Settings)
    (Settings-resolve provider s (if (memo-drawing?) [] (current-setting-bindings)))))

;; A number that changes whenever a global value or a scope is added or
;; removed (with its plugin), so what a setting resolves to outside the
;; dynamic layer may have changed. What a scope looks up (a buffer's own
;; values) is its owner's to count. The contract's, not a provider's, so a
;; new provider never repeats a number. On the baton only.
(def generation 0)

(def (settings-generation) => :fixnum
  (:- generation :fixnum))

(def (settings-changed!) => :void
  (set! generation (fx1+ (settings-generation))))

(def (context-set-setting! (ctx : context) (s : setting) (value : :t)) => :void
  (:- (with-service-provider (provider settings-service Settings)
        (context-defer! ctx settings-changed!)
        (context-defer! ctx (lambda () (setting-changed! s)))
        (Settings-add-global-value! provider ctx s value)
        (setting-changed! s)
        (settings-changed!)) :void))

(def (context-add-setting-scope! (ctx : context)
                                 (name : :symbol)
                                 (lookup : :procedure)
                                 priority: (priority : :fixnum := 0))
  => :void
  (:- (with-service-provider (provider settings-service Settings)
        (context-defer! ctx settings-changed!)
        (context-defer! ctx (lambda () (source-changed! scopes-source)))
        (Settings-add-scope! provider ctx name lookup priority)
        (source-changed! scopes-source)
        (settings-changed!)) :void))
