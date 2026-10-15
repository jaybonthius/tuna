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
;;; (use-plugin PLUGIN key: value ...) also gives PLUGIN options, which it
;;; declares with defplugin-options (tuna/lib/plugin-options.ss). Each
;;; value is data, written as it would be quoted: 8080, "SPC", #t, vim.
;;; Loading checks every option against the plugin's declaration and fails
;;; with every problem, each with its line, before anything changes.
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
        (only-in :tuna/configuration activate-plugin!)
        :tuna/lib/configuration)
(export (import: :tuna/prelude)
        use-plugin
        activate-plugin!
        init-user-code
        (phi: +1 read-module-body))

(begin-syntax
  ;; The use-plugin form STX declaring PLUGIN with OPTIONS (expressions
  ;; from option-expression) and, unless BODY is #f, a config: block.
  (def (use-plugin-expansion stx plugin options body)
    (with-syntax ((plugin-name plugin)
                  (source (stx-source-string stx))
                  ((option ...) options))
      (if body
        (with-syntax (((body ...) body)
                      (block (stx-identifier plugin plugin "/config")))
          #'(declare-plugin! plugin-name
                             (let ()
                               (defplugin block "Code attached to a plugin by a config: block in init.ss."
                                 requires: [] unchecked: #t body ...)
                               block)
                             '(body ...)
                             source
                             (list option ...)))
        #'(declare-plugin! plugin-name #f [] source (list option ...)))))

  ;; One option, KEY: VALUE, as an expression for (name value "file:line").
  ;; VALUE is data, never evaluated, so no code of the user's runs at load:
  ;; a word without quotes is a symbol, and 'x is the same as x.
  (def (option-expression key value stx)
    (with-syntax ((name (string->symbol (keyword->string (stx-e key))))
                  (datum (if (and (stx-pair? value)
                                  (eq? (stx-e (stx-car value)) 'quote)
                                  (stx-pair? (stx-cdr value)))
                           (stx-car (stx-cdr value))
                           value))
                  (source (or (stx-source-string key) (stx-source-string stx))))
      #'(list 'name 'datum source))))

(defsyntax (use-plugin stx)
  (syntax-case stx ()
    ((_ plugin-name . clauses)
     (identifier? #'plugin-name)
     (let loop ((rest #'clauses) (options []))
       (cond
        ((stx-null? rest)
         (use-plugin-expansion stx #'plugin-name (reverse options) #f))
        ((and (stx-pair? rest) (eq? (stx-e (stx-car rest)) 'config:))
         ;; A keyword here is an option written after config:, which
         ;; would otherwise become code of the block.
         (let (stray (let find-keyword ((body (stx-cdr rest)))
                       (cond
                        ((not (stx-pair? body)) #f)
                        ((stx-keyword? (stx-car body)) (stx-car body))
                        (else (find-keyword (stx-cdr body))))))
           (when stray
             (raise-syntax-error #f "use-plugin options go before config:, not in its code"
                                 stx stray)))
         (use-plugin-expansion stx #'plugin-name (reverse options) (stx-cdr rest)))
        ((and (stx-pair? rest) (stx-keyword? (stx-car rest)) (stx-pair? (stx-cdr rest)))
         (loop (stx-cdr (stx-cdr rest))
               (cons (option-expression (stx-car rest) (stx-car (stx-cdr rest)) stx) options)))
        (else
         (raise-syntax-error #f "use-plugin takes a plugin name, then option: value pairs, then config: and code"
                             stx (if (stx-pair? rest) (stx-car rest) rest))))))))

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
            requires: [] unchecked: #t body ...)
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
