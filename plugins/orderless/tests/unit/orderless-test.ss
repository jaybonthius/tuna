prelude: :gerbil/core
(import :std/test :tuna/plugins/orderless/plugin)
(export orderless-test)

(def orderless-test
  (test-suite "orderless matching"
    (test-case "all components, any order, ignoring repeated and edge spaces"
      (check ((orderless-compile " sel  view ") "select-view-left") => [(cons 0 3) (cons 7 11)])
      (check ((orderless-compile "view sel") "select-view-left") => [(cons 7 11) (cons 0 3)])
      (check ((orderless-compile "view missing") "select-view-left") => #f)
      (check ((orderless-compile "   ") "anything") => []))
    (test-case "smart case belongs to each component, with character offsets"
      (check ((orderless-compile "view Sel") "Select-View") => [(cons 7 11) (cons 0 3)])
      (check ((orderless-compile "View") "select-view") => #f)
      (check ((orderless-compile "é") "CAFÉ") => [(cons 3 4)])
      (check ((orderless-compile "É") "café") => #f))
    (test-case "valid regexps, literal preference and invalid regexp fallback"
      (check ((orderless-compile "^sel v.*left$") "select-view-left") => [(cons 0 3) (cons 7 16)])
      (check ((orderless-compile "^SEL") "select-view") => #f)
      (check ((orderless-compile "a.b") "a.b axb") => [(cons 0 3)])
      (check ((orderless-compile "a.b") "axb") => [(cons 0 3)])
      (check ((orderless-compile "[") "a[b") => [(cons 1 2)])
      (check ((orderless-compile "[") "abc") => #f)
      (check ((orderless-compile "\\S+") " two words") => [(cons 1 4)]))
    (test-case "overlapping components and zero-width regexp matches retain every span"
      (check ((orderless-compile "sel elect") "select") => [(cons 0 3) (cons 1 6)])
      (check ((orderless-compile "^ $") "name") => [(cons 0 0) (cons 4 4)]))))
