;;; Demo commands for the architecture skeleton (stage 1): endless commands
;;; to quit, and describe-services.
prelude: :gerbil/core

(import :tuna/kernel
        :tuna/services/keys)
(export demo-plugin
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
                            (string-join (map symbol->string dependents) ", ")))))
       (describe-services)))

(defplugin (demo-plugin ctx)
  "Demo commands: endless loops to quit with C-g, and describe-services."
  requires: [input-service]
  (define-command ctx (loop-forever) "Loop until quit, checking for quit."
    (message "Looping forever, checking for quit. Press C-g.")
    (redisplay)
    (let lp () (check-quit) (lp)))
  (define-command ctx (loop-forever-ignoring-quit) "Loop until quit, never checking for quit."
    (message "Looping forever without checking for quit. Press C-g.")
    (redisplay)
    ;; Counting keeps gxc -O from hanging on an empty self-loop.
    (let lp ((n 0)) (lp (fxand (fx1+ n) #xffff))))
  (define-command ctx (describe-services) "Show each service's tier, provider, and dependents."
    (show-help "Services" (services-description)))
  (keymap-set ctx "C-c l" 'loop-forever)
  (keymap-set ctx "C-c L" 'loop-forever-ignoring-quit)
  (keymap-set ctx "C-h s" 'describe-services))
