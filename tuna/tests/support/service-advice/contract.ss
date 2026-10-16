prelude: :gerbil/core
package: tuna/tests/support/service-advice
(import :tuna/kernel)
(export (service-interface-out Counter) counter-service)

(service-interface Counter
  (step (n : :fixnum)) => :fixnum
  (inline (n : :fixnum)) => :fixnum
  (multiple) => :values)
(def counter-service
  (new-service 'advice-counter is-Counter? tier: 'live doc: "Service advice fixture."))
