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
        last-configuration-report)

(interface Configuration
  ;; Load init.ss again as a trial, apply what changed, and return the
  ;; reload report. The caller holds the baton.
  (reload!) => :string
  ;; The report of the last start-up or reload, or #f before either.
  (last-report) => (Maybe :string))

(def configuration-service
  (new-service 'configuration is-Configuration? tier: 'live
               doc: "Reloads init.ss and keeps the last start-up or reload report."))

(def (current-configuration) => Configuration
  (let (provider (service-provider configuration-service))
    (unless provider
      (error "Nothing provides the configuration service"))
    (Configuration provider)))

(def (reload-configuration-report) => :string
  (Configuration-reload! (current-configuration)))

(def (last-configuration-report) => (Maybe :string)
  (Configuration-last-report (current-configuration)))
