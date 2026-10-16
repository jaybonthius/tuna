;;; Actual service advice preserves Keys' richer Input interface and Commands routing.
prelude: :gerbil/core
(import :std/test :std/interface :tuna/kernel
        (only-in :tuna/prelude advise! unadvise! advice-for advice-target-info-advice)
        :tuna/plugins/commands/contract :tuna/plugins/commands/plugin
        :tuna/plugins/keys/contract :tuna/plugins/keys/plugin
        "../../tuna/tests/support/kernel")
(export service-advice-test)

(def service-advice-test
  (test-suite "service advice across real plugins"
    (test-case "qualified Input calls run once; service advice surrounds command advice"
      (let ((owner #f) (calls []) (arrivals 0))
        (defplugin (service-advisor ctx) "Only contracts, no private provider access."
          requires: [commands-service input-service]
          (set! owner ctx)
          (defcommand (observed) "Observed command." (set! calls (append calls '(body))))
          (advise! ctx (service input-service arrival) 'arrival
            before: (lambda (event) (set! arrivals (fx1+ arrivals))))
          (advise! ctx (service commands-service call-command) 'service
            before: (lambda (name) (set! calls (append calls '(service)))))
          (advise! ctx (command observed) 'command
            before: (lambda () (set! calls (append calls '(command))))))
        (call-with-fresh-kernel [commands keys]
          (lambda ()
            (let ((raw-input (service-provider input-service))
                  (raw-commands (service-provider commands-service))
                  (event (make-key-event 1 "a" "" 0 #f #f #f #f #f #f #f #f #f #f)))
              (activate-plugin! service-advisor)
              (let (wrapped (service-provider input-service))
                (check (is-Keys? wrapped) => #t)
                (check (Input-arrival wrapped event) => 'queue)
                (check (Keys-arrival (Keys (Input wrapped)) event) => 'queue)
                (check arrivals => 2))
              (call-command 'observed)
              (check calls => '(service command body))
              (check (length (advice-target-info-advice (advice-for (command observed)))) => 1)
              (unadvise! owner (service commands-service call-command) 'service)
              (check (eq? (service-provider commands-service) raw-commands) => #t)
              (set! calls [])
              (call-command 'observed)
              (check calls => '(command body))
              (deactivate-plugin! service-advisor)
              (check (eq? (service-provider input-service) raw-input) => #t)
              (check (command-entry 'observed) => #f))))))))
