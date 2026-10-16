prelude: :gerbil/core
(import :std/test :std/source :std/misc/process
        "../support/service-interfaces/caller")
(export service-interface-test)

(def compiled-proof
  (path-expand "../support/service-interfaces/compiled.sh" (this-source-directory)))
(def service-interface-test
  (test-suite "tuna/kernel/service-interface"
    (test-case "complete inherited views, forwarding, shared state and checked results"
      (check (check-preservation) => (void)))
    (test-case "separately compiled declarations and typed callers"
      (check (run-process [compiled-proof]) => "SERVICE-VIEW-PRESERVATION-PASS\n"))))
