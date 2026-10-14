;;; The configuration contract: reload init.ss, and read the last start-up
;;; or reload report. Tuna's start-up code (tuna/boot.ss) provides it, so
;;; plugins such as reload-config reach the configuration through this
;;; service rather than by importing program code (ADR 12).
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel)
(export (interface-out Configuration)
        configuration-service
        reload-configuration-report
        last-configuration-report
        swap-plugins)

(interface Configuration
  ;; Load init.ss again as a trial, apply what changed, and return the
  ;; reload report. The caller holds the baton.
  (reload!) => :string
  ;; Replace OLD by NEW (or turn OLD off with #f), including saved state.
  ;; Startup-only closures are deferred to a process restart.
  (swap! (old : plugin) (new :? plugin)) => :void
  ;; The report of the last start-up or reload, or #f before either.
  (last-report) => (Maybe :string))

(def configuration-service
  (new-service 'configuration is-Configuration? tier: 'live
               doc: "Reloads init.ss and keeps the last start-up or reload report."))

(def (reload-configuration-report) => :string
  (:- (with-service-provider (provider configuration-service Configuration) (Configuration-reload! provider)) :string))

(def (last-configuration-report) => (Maybe :string)
  (:? (with-service-provider (provider configuration-service Configuration) (Configuration-last-report provider)) :string))

(def (swap-plugins (old : plugin) (new :? plugin)) => :void
  (:- (with-service-provider (provider configuration-service Configuration)
    (Configuration-swap! provider old new)) :void))
