;;; The configuration language: init.ss starts with `#lang :tuna/config`.
;;; It is Tuna's package language (:tuna/prelude) plus `use-plugin`, and
;;; it splits the file in two:
;;;
;;; - `import` and `use-plugin` forms run when Tuna loads the file.
;;;   `use-plugin` only collects a declaration (tuna/lib/configuration.ss)
;;;   and changes nothing in the running editor.
;;; - Every other top-level form is the user's own code. It becomes the
;;;   body of one more plugin, `init`, which Tuna activates last, so its
;;;   effects go through a context and its receipt undoes them (ADR 2).
;;;   Its definitions are local to that body: config: blocks cannot see
;;;   them, so helpers both use go in a module that init.ss imports by a
;;;   string path, which resolves against the directory of init.ss.
;;;
;;; (use-plugin PLUGIN) declares a plugin; it does not turn it on. PLUGIN
;;; must be a name, so no expression of the user's runs at load.
;;; (use-plugin PLUGIN config: BODY ...) also declares BODY as a block of
;;; code attached to PLUGIN: a plugin of its own, named PLUGIN/config, that
;;; is on while PLUGIN is on and fails without affecting PLUGIN.
;;;
;;; Two kinds of code still run at load, and must not change the editor,
;;; because nothing could undo it: the bodies of the modules init.ss
;;; imports (Gerbil runs a module's body when it is first imported), and
;;; macro code (phase 1), which runs while the file is expanded. Plugin
;;; modules only define plugins, so importing them is safe.
prelude: :gerbil/core

(import (except-in :tuna/prelude read-module-body)
        :tuna/kernel
        :tuna/lib/configuration)
(export (import: :tuna/prelude)
        use-plugin
        init-user-code
        (phi: +1 read-module-body))

(defsyntax (use-plugin stx)
  (syntax-case stx ()
    ((_ plugin-name)
     (identifier? #'plugin-name)
     (with-syntax ((source (stx-source-string stx)))
       #'(declare-plugin! plugin-name #f [] source)))
    ((_ plugin-name config: body ...)
     (identifier? #'plugin-name)
     (with-syntax ((source (stx-source-string stx))
                   (block (stx-identifier #'plugin-name #'plugin-name "/config")))
       #'(declare-plugin! plugin-name
                          (let ()
                            (defplugin block "Code attached to a plugin by a config: block in init.ss."
                              requires: [] body ...)
                            block)
                          '(body ...)
                          source)))))

;; The user's own code, as the plugin `init`. The reader below emits it;
;; init.ss does not call it directly.
(defsyntax (init-user-code stx)
  (syntax-case stx ()
    ((_ body ...)
     #'(declare-user-code!
        (let ()
          ;; An explicit requires: makes a leading requires: of the user's
          ;; an ordinary expression of the body.
          (defplugin init "Your own code in init.ss, activated after the plugins it declares."
            requires: [] body ...)
          init)
        '(body ...)))))

(begin-syntax
  ;; Keep import, export, and use-plugin forms at the top level; wrap
  ;; every other form, in order, in one init-user-code form.
  (def (read-module-body port)
    (let lp ((top []) (code []))
      (let (next (read-syntax port))
        (cond
         ((eof-object? next)
          (append (reverse top) [(cons 'init-user-code (reverse code))]))
         ((load-time-form? next) (lp (cons next top) code))
         (else (lp top (cons next code)))))))

  (def (load-time-form? stx)
    (and (stx-pair? stx)
         (identifier? (stx-car stx))
         (memq (stx-e (stx-car stx)) '(import export use-plugin))
         #t)))
