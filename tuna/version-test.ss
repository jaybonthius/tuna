(import :std/test
        :tuna/version)
(export version-test)

(def version-test
  (test-suite "tuna/version"
    (test-case "reports a version string"
      (check (string? (tuna-version)) => #t))))
