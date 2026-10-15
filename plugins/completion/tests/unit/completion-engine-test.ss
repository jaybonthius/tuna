prelude: :gerbil/core
(import :std/test :tuna/plugins/completion/plugin)
(export completion-engine-test)

(def completion-engine-test
  (test-suite "completion pipeline"
    (test-case "substring smart case and half-open highlights"
      (check ((substring-compile "buf") "Buffer-buffer") => [(cons 0 3)])
      (check ((substring-compile "Buf") "buffer") => #f)
      (check ((substring-compile "Buf") "Buffer") => [(cons 0 3)])
      (check ((substring-compile "") "anything") => [])
      (check ((substring-compile "é") "café") => [(cons 3 4)]))
    (test-case "history recency, then length, name and stable source index"
      (let (texts '#("bbb" "aa" "a" "ab" "aa"))
        (check (map car (completion-pipeline texts "" ["bbb" "ab"] [substring-compile]))
               => [0 3 2 1 4])
        (check (map car (completion-pipeline texts "a" [] [substring-compile])) => [2 1 4 3])))
    (test-case "table sorting sees only indexed text in source order, with spans kept"
      (check (completion-pipeline '#("zz" "a" "ab") "a" ["ab"] [substring-compile]
               (lambda (rows)
                 (check rows => [(cons 1 "a") (cons 2 "ab")])
                 (reverse rows)))
             => [(cons 2 [(cons 0 1)]) (cons 1 [(cons 0 1)])]))
    (test-case "styles fall through only when the earlier style has no matches"
      (let ((none (lambda (input) (lambda (text) #f)))
            (all (lambda (input) (lambda (text) []))))
        (check (map car (completion-pipeline '#("abc" "xy") "bc" [] [none substring-compile all])) => [0])
        (check (map car (completion-pipeline '#("abc" "xy") "no" [] [none substring-compile all])) => [1 0])
        (check (completion-pipeline '#("abc") "no" [] [substring-compile]) => [])))))
