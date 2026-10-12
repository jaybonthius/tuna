(import :std/error
        :std/test
        :tuna/kernel
        :tuna/lib/jobs
        :tuna/services/text-store
        :tuna/services/buffers
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/string-text-store
        :tuna/plugins/buffers
        "../test-support/kernel")
(export buffers-test)

(def buffer-plugins
  [rope-text-store-plugin settings-plugin buffers-plugin])

(def (raises? thunk)
  (with-catch (lambda (e) #t) (lambda () (thunk) #f)))

(def (spans-of spans) (map (lambda (s) [(span-start s) (span-end s)]) spans))

(def buffers-test
  (test-suite "tuna/services/buffers"
    (test-case "*scratch* is a tree holding one empty text node"
      (call-with-fresh-kernel buffer-plugins
       (lambda ()
         (check (buffer-name (current-buffer)) => "*scratch*")
         (check (text-node? (buffer-root (current-buffer))) => #t)
         (check (eq? (current-text-node) (buffer-root (current-buffer))) => #t)
         (check (point) => 1)
         (check (point-max) => 1))))

    (test-case "positions count characters from 1; lines from 1, columns from 0"
      (call-with-fresh-kernel buffer-plugins
       (lambda ()
         (let (t (current-text))
           ;; h é l l o _ 😀 | \n | w ö r l d
           (insert "héllo 😀\nwörld")
           (check (point) => 14)
           (check (point-max) => 14)
           (check (text-substring t 7 8) => "😀")
           (check (text-line-count t) => 2)
           (check (text-line-at t 8) => 1)
           (check (text-line-at t 9) => 2)
           (check (text-line-start t 2) => 9)
           (check (text-line-end t 1) => 8)
           (check (text-line-end t 2) => 14)
           (check (text-column t 7) => 6)
           (check (text-column t 11) => 2)
           (check (text-position-at t 2 3) => 12)
           (check (text-position-at t 1 100) => 8)
           (check (raises? (lambda () (text-substring t 0 1))) => #t)
           (check (raises? (lambda () (text-substring t 1 15))) => #t)
           (check (raises? (lambda () (text-line-start t 3))) => #t)
           (goto-char 100)
           (check (point) => 14)
           (goto-char 0)
           (check (point) => 1)))))

    (test-case "undo removes one group at a time; undoing after a break redoes"
      (call-with-fresh-kernel buffer-plugins
       (lambda ()
         (let (t (current-text))
           (insert "a")
           (insert "b")
           (undo-boundary! t)
           (insert "c")
           (check (text-undo! t #f) => 3)
           (check (text-string t) => "ab")
           (check (text-undo! t #t) => 1)
           (check (text-string t) => "")
           (check (raises? (lambda () (text-undo! t #t))) => #t)
           (text-undo! t #f)
           (check (text-string t) => "ab")))))

    (test-case "points relocate through changes made elsewhere"
      (call-with-fresh-kernel buffer-plugins
       (lambda ()
         (let (t (current-text))
           (insert "hello world")
           (goto-char 7)
           (text-replace! t 1 1 "XX")
           (check (point) => 9)
           (text-replace! t 1 3 "")
           (check (point) => 7)
           (text-replace! t 5 9 "")
           (check (point) => 5)
           (check (text-string t) => "hellrld")))))

    (test-case "the buffers plugin adapts to a new text store: every text, point, and undo survive"
      (call-with-fresh-kernel buffer-plugins
       (lambda ()
         (defplugin (adds-other ctx)
           "Adds a second buffer."
           (context-add-buffer! ctx (new-buffer "other" (new-text-node (new-text "second ☃ buffer")))))
         (activate-plugin! adds-other)
         (let ((other-text (text-node-content (buffer-root (get-buffer "other"))))
               (t (current-text))
               (registry (service-provider buffers-service))
               (stored-as-string? (lambda (t) (string? (snapshot-version (text-snapshot t))))))
           (insert "hello\nwörld 😀")
           (goto-char 4)
           (check (stored-as-string? t) => #f)
           (activate-plugin! string-text-store-plugin)
           (check (eq? (service-provider text-store-service) string-text-store) => #t)
           ;; Adapting, not restarting: the same provider object, texts moved.
           (check (eq? (service-provider buffers-service) registry) => #t)
           (check (stored-as-string? t) => #t)
           (check (stored-as-string? other-text) => #t)
           (check (text-string t) => "hello\nwörld 😀")
           (check (point) => 4)
           (undo-boundary! t)
           (insert "p")
           (check (text-string t) => "helplo\nwörld 😀")
           (check (text-string other-text) => "second ☃ buffer")
           (deactivate-plugin! string-text-store-plugin)
           (check (eq? (service-provider buffers-service) registry) => #t)
           (check (stored-as-string? t) => #f)
           (check (stored-as-string? other-text) => #f)
           (check (text-string t) => "helplo\nwörld 😀")
           (check (point) => 5)
           (text-undo! t #f)
           (check (text-string t) => "hello\nwörld 😀")))))

    (test-case "describe-services lists buffers as an adapting dependent of the text store"
      (call-with-fresh-kernel buffer-plugins
       (lambda ()
         (let (info (find (lambda (info) (eq? (service-info-name info) 'text-store))
                          (describe-services)))
           (check (service-info-dependents info) => '(buffers-plugin))
           (check (service-info-adapting info) => '(buffers-plugin))))))

    (test-case "without any text store, the buffers plugin goes too"
      (call-with-fresh-kernel buffer-plugins
       (lambda ()
         (activate-plugin! string-text-store-plugin)
         (deactivate-plugin! rope-text-store-plugin)
         (check (plugin-active? buffers-plugin) => #t)
         (deactivate-plugin! string-text-store-plugin)
         (check (plugin-active? buffers-plugin) => #f)
         (activate-plugin! rope-text-store-plugin)
         (check (plugin-active? buffers-plugin) => #t))))

    (test-case "undo puts point back where the command left it"
      (call-with-fresh-kernel buffer-plugins
       (lambda ()
         (let (t (current-text))
           (insert "abc")
           (goto-char 2)
           (undo-boundary! t)
           (delete-region 2 3)            ; a forward delete, point before it
           (check (text-undo! t #f) => 2)
           (check (text-string t) => "abc")
           (goto-char 3)
           (undo-boundary! t)
           (delete-region 2 3)            ; a backward delete, point after it
           (check (text-undo! t #f) => 3)
           (check (text-string t) => "abc")))))

    (test-case "highlights relocate with edits and change only the decoration revision"
      (call-with-fresh-kernel buffer-plugins
       (lambda ()
         (let (t (current-text))
           (insert "ab12cd345")
           (let ((content (text-content-revision t))
                 (decoration (text-decoration-revision t)))
             (set-highlights! t 'digits [(make-span 3 5 'digit) (make-span 7 10 'digit)])
             (check (text-content-revision t) => content)
             (check (> (text-decoration-revision t) decoration) => #t))
           (text-replace! t 1 1 "XY")       ; before both: both shift
           (text-replace! t 5 5 "<")        ; at the first's start: stays outside
           (text-replace! t 11 12 "")       ; inside the second: it shrinks
           (check (text-string t) => "XYab<12cd35")
           (check (map (lambda (s) [(span-start s) (span-end s)]) (text-highlights t 'digits))
                  => [[6 8] [10 12]])
           (text-replace! t 6 8 "")         ; all of the first: it goes
           (check (length (text-highlights t 'digits)) => 1)))))

    (test-case "a text's changes since a revision come oldest first, while the journal reaches back"
      (call-with-fresh-kernel buffer-plugins
       (lambda ()
         (let (t (current-text))
           (insert "a")
           (let (revision (text-chars-revision t))
             (insert "b")
             (insert "c")
             (check (map change-inserted (text-changes-since t revision)) => ["b" "c"])
             (check (text-changes-since t (text-chars-revision t)) => [])
             (for-each (lambda (_) (insert "x")) (iota 1100))
             (check (text-changes-since t revision) => #f))))))

    (test-case "rebase-spans shifts, keeps edges, and drops touched spans"
      (let (spans [(make-span 3 5 'a) (make-span 7 9 'b)])
        (check (spans-of (rebase-spans spans [(make-change 1 3 "" "xy")])) => [[5 7] [9 11]])
        (check (spans-of (rebase-spans spans [(make-change 1 5 "" "xy")])) => [[3 5] [9 11]])
        (check (spans-of (rebase-spans spans [(make-change 1 4 "" "x")])) => [[8 10]])
        (check (spans-of (rebase-spans spans [(make-change 1 1 "ab" "")])) => [[1 3] [5 7]])
        (check (spans-of (rebase-spans spans [(make-change 1 4 "abc" "")])) => [[4 6]])))

    (test-case "a text rebases job spans past its changes, until its journal no longer reaches back"
      (call-with-fresh-kernel buffer-plugins
       (lambda ()
         (let (t (current-text))
           (insert "a12b34")
           (let ((target (JobTarget t))
                 (revision (text-chars-revision t))
                 (spans [(make-span 2 4 'digit) (make-span 5 7 'digit)]))
             (text-replace! t 1 1 "xx")     ; "xxa12b34": both shift by 2
             (text-replace! t 8 8 "!")      ; inside 34: that span is dropped
             (check (map spans-of (JobTarget-job-rebase target spans revision)) => [[[4 6]]])
             (for-each (lambda (_) (insert "x")) (iota 1100))
             (check (JobTarget-job-rebase target spans revision) => #f))))))

    (test-case "node kinds come and go with their plugin; projections need no renderer"
      (call-with-fresh-kernel buffer-plugins
       (lambda ()
         (defplugin (box-kind ctx)
           "Defines the box node kind."
           (context-define-node-kind! ctx 'box doc: "A box."
                                      project: (lambda (n) (node-attribute n 'label))))
         (let (tree (new-node 'column
                              children: [(new-node 'box attributes: [['label . "Box"]])
                                         (new-text-node (new-text "text"))]))
           (check (node-kind-ref 'box) => #f)
           (activate-plugin! box-kind)
           (check (node-kind-info-name (node-kind-ref 'box)) => 'box)
           (check (node-text-projection tree) => "Box\ntext")
           (check (text-node? (first-text-node tree)) => #t)
           (deactivate-plugin! box-kind)
           (check (node-kind-ref 'box) => #f)
           (check (node-text-projection tree) => "\ntext")))))))
