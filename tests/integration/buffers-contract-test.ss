;;; The buffers contract, checked against both providers: the default
;;; (tuna/plugins/buffers.ss) and the toy (tuna/test-support/toy-buffers.ss).
;;; Each provider runs alone with a text store and settings.
;;; Restart and restore are integration-tested with session and autosave.
(import :std/error
        :std/test
        :tuna/kernel
        :tuna/lib/jobs
        :tuna/plugins/text-store/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        "../../plugins/text-store/tests/support/string-text-store"
        :tuna/plugins/buffers/plugin
        "../../plugins/buffers/tests/support/toy-buffers"
        "../../tuna/tests/support/kernel")
(export buffers-test
        toy-buffers-test)

(def (raises? thunk)
  (with-catch (lambda (e) #t) (lambda () (thunk) #f)))

(def (spans-of spans) (map (lambda (s) [(span-start s) (span-end s)]) spans))

(defsetting fill-width 70 "A setting for buffer-local values.")

;; The contract's cases, run with PROVIDER as the buffers plugin.
(def (buffers-contract-cases provider)
  (def buffer-plugins [rope-text-store settings provider])

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
         (check (text-string t) => "abc")
         (text-clear-undo! t)
         (check (raises? (lambda () (text-undo! t #f))) => #t)))))

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
         (check (text-string t) => "hellrld")
         (check (relocate-position t 1 0) => 1)))))

  (test-case "without any text store, the provider goes too"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (deactivate-plugin! rope-text-store)
       (check (plugin-active? provider) => #f)
       (activate-plugin! rope-text-store)
       (check (plugin-active? provider) => #t))))

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
         (check (spans-of (text-highlights t 'digits)) => [[6 8] [10 12]])
         (check (length (text-all-highlights t)) => 2)
         (text-replace! t 6 8 "")         ; all of the first: it goes
         (check (length (text-highlights t 'digits)) => 1)
         (check (text-highlights t 'other) => [])))))

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

  (test-case "rebase-spans and highlights follow the same rule"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (let (t (current-text))
         (insert "ab12cd345ef")
         (let ((revision (text-chars-revision t))
               (spans [(make-span 3 5 'digit) (make-span 7 10 'digit)]))
           (set-highlights! t 'digits spans)
           (text-replace! t 1 1 "XY")
           (text-replace! t 5 5 "<")
           (text-replace! t 7 7 "9")
           (text-replace! t 11 13 "")
           (text-replace! t 12 12 ">")
           (check (text-string t) => "XYab<192cd5>ef")
           (check (spans-of (text-highlights t 'digits)) => [[6 9] [11 12]])
           (check (spans-of (rebase-spans spans (text-changes-since t revision)))
                  => (spans-of (text-highlights t 'digits))))))))

  (test-case "a text rebases job spans past its changes, until its journal no longer reaches back"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (let (t (current-text))
         (insert "a12b34")
         (let ((target (JobTarget t))
               (revision (text-chars-revision t))
               (spans [(make-span 2 4 'digit) (make-span 5 7 'digit)]))
           (text-replace! t 1 1 "xx")     ; "xxa12b34": both shift by 2
           (text-replace! t 8 8 "!")      ; inside 34: that span grows
           (check (JobTarget-job-revision target) => (text-chars-revision t))
           (check (JobTarget-job-target-alive? target) => #t)
           (check (map spans-of (JobTarget-job-rebase target spans revision)) => [[[4 6] [7 10]]])
           (for-each (lambda (_) (insert "x")) (iota 1100))
           (check (JobTarget-job-rebase target spans revision) => #f))))))

  (test-case "after-change-hook receives each change after the text has it"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (let ((seen [])
             (t (current-text)))
         (defplugin (watcher ctx)
           "Records changes."
           requires: [buffers-service]
           (context-add-hook! ctx after-change-hook 'record
                              (lambda (text c) (set! seen (cons [(text-string text) (change-inserted c)] seen)))))
         (activate-plugin! watcher)
         (insert "ab")
         (delete-region 1 2)
         (check (reverse seen) => [["ab" "ab"] ["b" ""]])))))

  (test-case "nodes have one parent, a child count, and children by range"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (let* ((items (map (lambda (i) (new-node 'item attributes: [['n . i]])) (iota 5)))
              (text-node (new-text-node (new-text "t")))
              (tree (new-node 'column children: (append items [text-node]))))
         (check (node-kind tree) => 'column)
         (check (node-parent tree) => #f)
         (check (node-child-count tree) => 6)
         (check (map (cut node-attribute <> 'n) (node-children tree 1 3)) => [1 2])
         (check (length (node-children tree)) => 6)
         (check (node-children tree 6 6) => [])
         (check (raises? (lambda () (node-children tree 4 7))) => #t)
         (check (eq? (node-parent (car items)) tree) => #t)
         (check (eq? (first-text-node tree) text-node) => #t)
         (check (text-node? (car items)) => #f)
         (check (raises? (lambda () (new-node 'other children: [(car items)]))) => #t)
         (let (b (new-buffer "tree" tree))
           (add-buffer! b)
           (check (eq? (buffer-root b) tree) => #t)
           (check (eq? (buffer-point-node b) text-node) => #t)
           (check (buffer-texts b) => [(text-node-content text-node)]))
         (set-node-children! tree (cdr items))
         (check (node-parent (car items)) => #f)
         (check (node-parent text-node) => #f)
         (check (node-child-count tree) => 4)))))

  (test-case "buffer-texts lists the texts of the text nodes depth first, in tree order"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (let* ((texts (map new-text ["a" "b" "c" "d"]))
              (leaves (map new-text-node texts))
              (b (new-buffer "ordered"
                             (new-node 'column
                                       children: [(car leaves)
                                                  (new-node 'column children: [(cadr leaves) (caddr leaves)])
                                                  (cadddr leaves)]))))
         (add-buffer! b)
         (check (map text-string (buffer-texts b)) => ["a" "b" "c" "d"])))))

  (test-case "a change stamps its node and every node above it with a new, larger revision"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (let* ((t (new-text "abc"))
              (leaf (new-text-node t))
              (other (new-node 'item))
              (section (new-node 'section children: [leaf]))
              (root (new-node 'root children: [section other])))
         (def (revisions) (map node-revision [leaf section root other]))
         (let (before (revisions))
           (text-replace! t 1 1 "x")
           (let (after (revisions))
             (check (> (car after) (car before)) => #t)
             (check (cadr after) => (car after))
             (check (caddr after) => (car after))
             (check (cadddr after) => (cadddr before))))
         (let (before (revisions))
           (set-highlights! t 'digits [])
           (check (> (node-revision root) (caddr before)) => #t)
           (check (node-revision other) => (cadddr before)))
         (let (before (node-revision root))
           (set-node-attribute! other 'label "Other")
           (check (node-attribute other 'label) => "Other")
           (check (> (node-revision other) before) => #t)
           (check (node-revision root) => (node-revision other))
           (check (> (node-revision root) (node-revision section)) => #t))
         (let (before (node-revision root))
           (set-node-children! section [])
           (check (> (node-revision root) before) => #t))))))

  (test-case "buffers: names are unique; a killed buffer leaves the selected view and its texts die"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (let* ((b (new-buffer "notes" (new-text-node (new-text "n"))))
              (t (text-node-content (buffer-root b)))
              (killed []))
         (defplugin (watcher ctx)
           "Records killed buffers."
           requires: [buffers-service]
           (context-add-hook! ctx kill-buffer-hook 'record
                              (lambda (b) (set! killed (cons (buffer-name b) killed)))))
         (activate-plugin! watcher)
         (add-buffer! b)
         (check (raises? (lambda () (add-buffer! (new-buffer "notes" (new-node 'x))))) => #t)
         (check (map buffer-name (buffer-list)) => ["*scratch*" "notes"])
         (check (raises? (lambda () (rename-buffer! b "*scratch*"))) => #t)
         (rename-buffer! b "notes2")
         (check (eq? (get-buffer "notes2") b) => #t)
         (switch-to-buffer b)
         (goto-char 2)
         (check (eq? (current-buffer) b) => #t)
         (check (text-live? t) => #t)
         (kill-buffer b)
         (check killed => ["notes2"])
         (check (buffer-name (current-buffer)) => "*scratch*")
         (check (map buffer-name (buffer-list)) => ["*scratch*"])
         (check (text-live? t) => #f)))))

  (test-case "a buffer keeps its point and settings while no view shows it"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (let ((scratch (current-buffer))
             (b (new-buffer "notes" (new-text-node (new-text "hello")))))
         (add-buffer! b)
         (set-buffer-point! b 3)
         (check (buffer-point b) => 3)
         (set-buffer-setting! b fill-width 40)
         (check (buffer-setting b fill-width) => (cons fill-width 40))
         (check (buffer-setting scratch fill-width) => #f)
         (switch-to-buffer b)
         (check (point) => 3)
         (check (setting-value fill-width) => 40)
         (goto-char 5)
         (switch-to-buffer scratch)
         (check (setting-value fill-width) => 70)
         (text-replace! (text-node-content (buffer-root b)) 1 1 "oh, ")
         (check (buffer-point b) => 9)
         (let (v (new-view b))
           (check (eq? (view-showing v) b) => #t)
           (check (view-point v) => 9)
           (check (= (view-id v) (view-id (selected-view))) => #f))))))

  (test-case "a node carries a keymap, given when it is made or later; giving one is a change"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (let* ((keymap (new-entry-table))
              (other (new-entry-table))
              (leaf (new-node 'item keymap: keymap))
              (plain (new-node 'item))
              (root (new-node 'column children: [leaf plain])))
         (check (eq? (node-keymap leaf) keymap) => #t)
         (check (node-keymap plain) => #f)
         (let (before (node-revision root))
           (set-node-keymap! plain other)
           (check (eq? (node-keymap plain) other) => #t)
           (check (> (node-revision plain) before) => #t)
           (check (node-revision root) => (node-revision plain)))
         (let (before (node-revision leaf))
           (set-node-keymap! leaf #f)
           (check (node-keymap leaf) => #f)
           (check (> (node-revision leaf) before) => #t))))))

  (test-case "buffer-list-update-hook runs after a buffer is added, renamed or killed"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (let ((b (new-buffer "notes" (new-text-node (new-text ""))))
             (seen []))
         (defplugin (lister ctx)
           "Records the buffer list whenever it changes."
           requires: [buffers-service]
           (context-add-hook! ctx buffer-list-update-hook 'record
                              (lambda () (set! seen (cons (map buffer-name (buffer-list)) seen)))))
         (activate-plugin! lister)
         (add-buffer! b)
         (rename-buffer! b "notes2")
         (kill-buffer b)
         (check (reverse seen) => [["*scratch*" "notes"] ["*scratch*" "notes2"] ["*scratch*"]])))))

  (test-case "node kinds come and go with their plugin; projections need no renderer"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (defplugin (box-kind ctx)
         "Defines the box node kind."
         requires: [buffers-service]
         (context-define-node-kind! ctx 'box doc: "A box."
                                    project: (lambda (n) (node-attribute n 'label))))
       (let (tree (new-node 'column
                            children: [(new-node 'box attributes: [['label . "Box"]])
                                       (new-text-node (new-text "text"))]))
         (check (node-kind-ref 'box) => #f)
         (check (node-kind-info-name (node-kind-ref 'text)) => 'text)
         (activate-plugin! box-kind)
         (check (node-kind-info-name (node-kind-ref 'box)) => 'box)
         (check (node-text-projection tree) => "Box\ntext")
         (check (text-node? (first-text-node tree)) => #t)
         (deactivate-plugin! box-kind)
         (check (node-kind-ref 'box) => #f)
         (check (node-text-projection tree) => "\ntext"))))))

(def buffers-test
  (test-suite "tuna/services/buffers: the default provider"
    (buffers-contract-cases buffers)

    (test-case "rebase-spans moves spans as highlights move and drops only emptied ones"
      (let (spans [(make-span 3 5 'a) (make-span 7 9 'b)])
        ;; Insertions at either edge stay outside.
        (check (spans-of (rebase-spans spans [(make-change 1 3 "" "xy")])) => [[5 7] [9 11]])
        (check (spans-of (rebase-spans spans [(make-change 1 5 "" "xy")])) => [[3 5] [9 11]])
        ;; An insertion inside grows the span.
        (check (spans-of (rebase-spans spans [(make-change 1 4 "" "x")])) => [[3 6] [8 10]])
        (check (spans-of (rebase-spans spans [(make-change 1 1 "ab" "")])) => [[1 3] [5 7]])
        ;; A deletion inside shrinks it.
        (check (spans-of (rebase-spans spans [(make-change 1 4 "abc" "")])) => [[3 4] [4 6]])
        ;; A span whose characters are all deleted goes.
        (check (spans-of (rebase-spans spans [(make-change 1 3 "ab" "")])) => [[5 7]])
        (check (spans-of (rebase-spans spans [(make-change 1 4 "" "x") (make-change 2 3 "axb" "")]))
               => [[5 7]])))))

(def toy-buffers-test
  (test-suite "tuna/services/buffers: the toy provider"
    (buffers-contract-cases toy-buffers)))

;; The provider's buffers as plain data: each buffer's name, text, and
;; point, and the selected view's buffer and point.
