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
        activate-plugin!
        evaluate-form
        evaluate-forms
        (struct-out configuration-report)
        configuration-started-hook
        configuration-stopping-hook
        configuration-report-ready-hook
        context-set-restart-wrapper!
        call-with-configuration-restart)

(interface Configuration
  ;; Checked package activation; raw runtime activation is not public.
  (activate! (target : plugin) (order :? :fixnum)) => :void
  ;; Load init.ss again as a trial, apply what changed, and return the
  ;; reload report. The caller holds the baton.
  (reload!) => :string
  ;; One around-restart participant; its context owns the registration.
  (set-restart-wrapper! (ctx : context) (wrapper : :procedure)) => :void
  (restart (owners : :list) (apply : :procedure) (rollback : :procedure)) => :void
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

(def (activate-plugin! (target : plugin) order: (rank :? :fixnum := #f)) => :void
  (:- (with-service-provider (provider configuration-service Configuration)
        (Configuration-activate! provider target rank)) :void))

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

;; Program lifecycle notifications carry no editor state. Hook callbacks are
;; receipt-owned and execute under their registering contexts.
(def configuration-started-hook
  (new-hook 'configuration-started doc: "All configured plugins have finished starting."))
(def configuration-stopping-hook
  (new-hook 'configuration-stopping doc: "Before any plugin is deactivated at shutdown."))
(def configuration-report-ready-hook
  (new-hook 'configuration-report-ready doc: "The finalized start-up report and its log path."))

;; ENTRIES are (status description) pairs, not plugin or editor values.
(defstruct configuration-report ((text : :string) (problem :? :string)
                                 (entries : :list) (log : :string)) final: #t)

;; WRAPPER receives (owner-names apply rollback). Capture must finish before
;; calling APPLY; it must restore after APPLY, and after ROLLBACK on failure.
;; Only one participant is needed today. A second registration is an error.
(def (context-set-restart-wrapper! (ctx : context) (wrapper : :procedure)) => :void
  (:- (with-service-provider (provider configuration-service Configuration)
        (Configuration-set-restart-wrapper! provider ctx wrapper)) :void))

(def (call-with-configuration-restart (owners : :list) (apply : :procedure)
                                       (rollback : :procedure)) => :void
  (if (service-provider configuration-service)
    (:- (with-service-provider (provider configuration-service Configuration)
          (Configuration-restart provider owners apply rollback)) :void)
    (with-catch (lambda (e) (rollback) (raise e)) apply)))
