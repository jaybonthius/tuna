;;; What a buffer's status line shows of its program's status records,
;;; as ghostel-status's mode-line label does.
(import :std/test
        :tuna/plugins/program-status/contract
        :tuna/plugins/program-status/plugin)
(export label-test)

(def labels '((working . "...") (blocked . "blocked") (done . "done") (error . "error")))

(def (record (id : :string) (state : :symbol) kind: (kind #f) progress: (progress #f) app: (app #f))
  (cons id (make-program-status-report id state kind progress app #f #f)))

(def label-test
  (test-suite "tuna/plugins/program-status: the status line's label"
    (test-case "the program's own record, its percentage or its kind"
      (check (status-label [(record "" 'working)] labels #t) => "[...]")
      (check (status-label [(record "" 'working progress: 40)] labels #t) => "[40%]")
      (check (status-label [(record "" 'blocked kind: 'permission app: "claude-code")] labels #t)
             => "[claude-code: blocked: permission]")
      (check (status-label [(record "" 'blocked kind: 'permission app: "claude-code")] labels #f)
             => "[blocked: permission]")
      (check (status-label [(record "" 'done)] labels #t) => "[done]")
      ;; A state without a label shows nothing.
      (check (status-label [(record "" 'idle)] labels #t) => #f)
      (check (status-label [] labels #t) => #f))

    (test-case "blocked and error records anywhere come first, counted"
      (check (status-label [(record "a/b" 'error) (record "" 'working) (record "c" 'blocked)] labels #t)
             => "[error ×2]")
      ;; Records under the program's own show only when pressing.
      (check (status-label [(record "a" 'working)] labels #t) => #f))))
