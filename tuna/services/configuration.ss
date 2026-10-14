;;; The configuration contract: reload init.ss, read reports, and evaluate
;;; interactive code in the live session. Tuna's start-up code (tuna/boot.ss)
;;; provides it, so plugins reach configuration and evaluation through this
;;; service rather than by importing program code (ADR 12).
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel)
(export (interface-out Configuration)
        configuration-service
        reload-configuration-report
        last-configuration-report
        swap-plugins
        evaluate-form
        evaluate-forms)

(interface Configuration
  ;; Load init.ss again as a trial, apply what changed, and return the
  ;; reload report. The caller holds the baton.
  (reload!) => :string
  ;; Replace OLD by NEW (or turn OLD off with #f), including saved state.
  ;; Startup-only closures are deferred to a process restart.
  (swap! (old : plugin) (new :? plugin)) => :void
  ;; The report of the last start-up or reload, or #f before either.
  (last-report) => (Maybe :string)
  ;; Evaluate one datum or syntax object in the session's persistent
  ;; environment. Effects belong to its always-on owner. The caller holds
  ;; the baton; exceptions propagate without rolling back earlier effects.
  (evaluate (form : :t)) => :t)

(def configuration-service
  (new-service 'configuration is-Configuration? tier: 'live
               doc: "Reloads init.ss, keeps reports, and evaluates live session code."))

(def (reload-configuration-report) => :string
  (:- (with-service-provider (provider configuration-service Configuration) (Configuration-reload! provider)) :string))

(def (last-configuration-report) => (Maybe :string)
  (:? (with-service-provider (provider configuration-service Configuration) (Configuration-last-report provider)) :string))

(def (swap-plugins (old : plugin) (new :? plugin)) => :void
  (:- (with-service-provider (provider configuration-service Configuration)
    (Configuration-swap! provider old new)) :void))

(def (evaluate-form (form : :t)) => :t
  (with-service-provider (provider configuration-service Configuration)
    (Configuration-evaluate provider form)))

;; Evaluate in order, stopping at the first error. Return the final form's
;; value, or void for no forms. Definitions remain visible to later calls.
(def (evaluate-forms (forms : :list)) => :t
  (let loop ((rest forms) (result (void)))
    (if (null? rest) result
      (loop (cdr rest) (evaluate-form (car rest))))))
