;;; Generated descriptions exercise real providers, not a registration shim.
prelude: :gerbil/core
(import :std/interface :std/test :tuna/kernel
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/contract :tuna/plugins/keys/plugin
        :tuna/plugins/settings/plugin :tuna/plugins/text-store/plugin
        :tuna/plugins/buffers/plugin :tuna/plugins/layout/plugin
        :tuna/plugins/echo-area/contract :tuna/plugins/echo-area/plugin
        "../../tuna/tests/support/kernel"
        "../../plugins/session/tests/support/session")
(export service-views-test)

(def owner #f)
(defplugin (binding-owner ctx)
  "Owns the binding registered through a generated facade."
  requires: [input-service]
  (set! owner ctx))

(def (event (key : :string)) => key-event
  (make-key-event 1 key "" 0 #f #f #f #f #f #f #f #f #f #f))

(def service-views-test
  (test-suite "generated descriptions with real service providers"
    (test-case "Keys retains Input paths and the same keymap state"
      (call-with-fresh-kernel [commands keys binding-owner]
        (lambda ()
          (let* ((raw (Keys (service-provider input-service)))
                 (calls [])
                 (description Keys-service-view)
                 (view ((service-view-build description) raw
                        (lambda (operation base)
                          (if (memq operation '(arrival resolve!))
                            (lambda args
                              (set! calls (append calls [operation]))
                              (apply base args))
                            base))))
                 (base-only ((service-view-build Input-service-view) raw
                             (lambda (operation base) base))))
            (check (is-Keys? base-only) => #f)
            (check (is-Keys? view) => #t)
            (check (Input-arrival (Input view) (event "a")) => 'queue)
            (check (Keys-arrival (Keys view) (event "a")) => 'queue)
            (check (Input-resolve! (Input view) (event "F12")) => #f)
            (check (Keys-resolve! (Keys (Input view)) (event "F12")) => #f)
            (check calls => '(arrival arrival resolve! resolve!))
            (let (generation (Keys-keymap-generation raw))
              (Keys-keymap-set! view owner "C-c q" 'generated #f)
              (check (entry-value (Keys-key-binding raw "C-c q")) => 'generated)
              (check (Keys-keymap-generation view) => (Keys-keymap-generation raw))
              (check (> (Keys-keymap-generation raw) generation) => #t))
            (check (service-provider input-service) => raw)))))
    (test-case "EchoArea retains Messages recasts and raw message state"
      (call-with-fresh-kernel
        [commands keys settings rope-text-store buffers no-session layout echo-area]
        (lambda ()
          (let* ((raw (EchoArea (service-provider messages-service)))
                 (calls 0)
                 (view ((service-view-build EchoArea-service-view) raw
                        (lambda (operation base)
                          (if (eq? operation 'message!)
                            (lambda (text)
                              (set! calls (fx1+ calls))
                              (base (string-append "[" text "]")))
                            base)))))
            (EchoArea-message! view "one")
            (check (EchoArea-current-message raw) => "[one]")
            (EchoArea-message! (EchoArea (Messages view)) "two")
            (check (EchoArea-current-message view) => "[two]")
            (check (EchoArea-current-message raw) => "[two]")
            (check calls => 2)
            (check (service-provider messages-service) => raw)))))))
