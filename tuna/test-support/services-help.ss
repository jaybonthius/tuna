;;; C-h s (describe-services): each service's tier, provider, and
;;; dependents in the help output, for tests that check what the kernel
;;; reports through a running editor.
prelude: :gerbil/core

(import :tuna/services/commands
        :tuna/kernel
        :tuna/services/keys
        :tuna/services/help)
(export services-help-plugin
        services-description)

;; One line per service: name, tier, provider, dependents.
(def (services-description) => :list
  (map (lambda ((info : service-info))
         (string-append (symbol->string (service-info-name info))
                        " (" (symbol->string (service-info-tier info)) ")"
                        "  provider: "
                        (let (provider (service-info-provider info))
                          (if provider (symbol->string provider) "none"))
                        "  dependents: "
                        (let (dependents (service-info-dependents info))
                          (if (null? dependents)
                            "none"
                            (string-join (map (lambda ((name : :symbol))
                                                (symbol->string name))
                                              dependents)
                                         ", ")))))
       (describe-services)))

(defplugin (services-help-plugin ctx)
  "C-h s shows each service's tier, provider, and dependents."
  requires: [commands-service input-service help-service]
  (define-command ctx (describe-services) "Show each service's tier, provider, and dependents."
    (show-help "Services" (services-description)))
  (keymap-set ctx "C-h s" 'describe-services))
