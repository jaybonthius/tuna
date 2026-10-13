;;; The configuration language: init.ss starts with `#lang :tuna/config`.
;;; It is Tuna's package language (:tuna/prelude) plus `use-plugin`, and
;;; it splits the file in two:
;;;
;;; - `import` and `use-plugin` forms run when Tuna loads the file. They
;;;   only collect declarations (tuna/lib/configuration.ss); they change
;;;   nothing in the running editor.
;;; - Every other top-level form is the user's own code. It becomes the
;;;   body of one more plugin, `init`, which Tuna activates last, so its
;;;   effects go through a context and its receipt undoes them (ADR 2).
;;;   Its definitions are local to that body.
;;;
;;; (use-plugin PLUGIN) declares a plugin; it does not turn it on.
;;; (use-plugin PLUGIN config: BODY ...) also declares BODY as a block of
;;; code attached to PLUGIN: a plugin of its own, named PLUGIN/config, that
;;; is on while PLUGIN is on and fails without affecting PLUGIN.
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
     (with-syntax ((source (stx-source-string stx)))
       #'(declare-plugin! plugin-name #f source)))
    ((_ plugin-name config: body ...)
     (identifier? #'plugin-name)
     (with-syntax ((source (stx-source-string stx))
                   (block (stx-identifier #'plugin-name #'plugin-name "/config")))
       #'(declare-plugin! plugin-name
                          (let ()
                            (defplugin block "Code attached to a plugin by a config: block in init.ss."
                              body ...)
                            block)
                          source)))))

;; The user's own code, as the plugin `init`. The reader below emits it;
;; init.ss does not call it directly.
(defsyntax (init-user-code stx)
  (syntax-case stx ()
    ((_ body ...)
     #'(declare-user-code!
        (let ()
          (defplugin init "Your own code in init.ss, activated after the plugins it declares."
            body ...)
          init)))))

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
