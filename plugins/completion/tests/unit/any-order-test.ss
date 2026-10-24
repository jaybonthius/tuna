prelude: :gerbil/core
(import :std/test :tuna/plugins/completion/plugin)
(export any-order-test)

(def any-order-test
  (test-suite "any-order matching"
    (test-case "all components, any order, ignoring repeated and edge spaces"
      (check ((any-order-compile " sel  view ") "select-view-left") => [(cons 0 3) (cons 7 11)])
      (check ((any-order-compile "view sel") "select-view-left") => [(cons 7 11) (cons 0 3)])
      (check ((any-order-compile "view missing") "select-view-left") => #f)
      (check ((any-order-compile "   ") "anything") => []))
    (test-case "smart case belongs to each component, with character offsets"
      (check ((any-order-compile "view Sel") "Select-View") => [(cons 7 11) (cons 0 3)])
      (check ((any-order-compile "View") "select-view") => #f)
      (check ((any-order-compile "é") "CAFÉ") => [(cons 3 4)])
      (check ((any-order-compile "É") "café") => #f))
    (test-case "valid regexps, literal preference and invalid regexp fallback"
      (check ((any-order-compile "^sel v.*left$") "select-view-left") => [(cons 0 3) (cons 7 16)])
      (check ((any-order-compile "^SEL") "select-view") => #f)
      (check ((any-order-compile "a.b") "a.b axb") => [(cons 0 3)])
      (check ((any-order-compile "a.b") "axb") => [(cons 0 3)])
      (check ((any-order-compile "[") "a[b") => [(cons 1 2)])
      (check ((any-order-compile "[") "abc") => #f)
      (check ((any-order-compile "\\S+") " two words") => [(cons 1 4)]))
    (test-case "overlapping components and zero-width regexp matches retain every span"
      (check ((any-order-compile "sel elect") "select") => [(cons 0 3) (cons 1 6)])
      (check ((any-order-compile "^ $") "name") => [(cons 0 0) (cons 4 4)]))))
