;;; The buffers contract, checked against both providers: the default
;;; (tuna/plugins/buffers.ss) and the toy (tuna/test-support/toy-buffers.ss).
;;; Each provider runs alone with a text store and settings.
;;; Restart and restore are integration-tested with session and autosave.
(import (only-in :gerbil/runtime/mop slot-ref)
        :std/error
        :std/interface
        :std/test
        :tuna/kernel
        :tuna/lib/jobs
        :tuna/plugins/text-store/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/buffers/contract
        (only-in :tuna/plugins/clients/contract make-client)
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        "../../plugins/text-store/tests/support/string-text-store"
        :tuna/plugins/buffers/plugin
        "../../plugins/buffers/tests/support/toy-buffers"
        "../../tuna/tests/support/kernel"
        "../../tuna/tests/support/redraws"
        :tuna/lib/memo)
(export buffers-test
        toy-buffers-test)

(def (raises? thunk)
  (with-catch (lambda (e) #t) (lambda () (thunk) #f)))

(def (spans-of spans) (map (lambda (s) [(span-start s) (span-end s)]) spans))

;; Whether span bounds (START END) come before (START* END*).
(def (span-pair<? a b)
  (or (< (car a) (car b)) (and (= (car a) (car b)) (< (cadr a) (cadr b)))))

(defsetting fill-width 70 "A setting for buffer-local values.")

;; Calls of the counting text store's line-count.
(def line-counts 0)

;; A text store counting how often lines are counted, otherwise the toy
;; store.
(defstruct counting-store () final: #t)

(implement TextStore counting-store
  (from-string (lambda (self text) (TextStore-from-string string-store-instance text)))
  (size (lambda (self version) (TextStore-size string-store-instance version)))
  (line-count (lambda (self version)
                (set! line-counts (+ line-counts 1))
                (TextStore-line-count string-store-instance version)))
  (slice (lambda (self version start end) (TextStore-slice string-store-instance version start end)))
  (line-at (lambda (self version position) (TextStore-line-at string-store-instance version position)))
  (line-start (lambda (self version line) (TextStore-line-start string-store-instance version line)))
  (for-each-chunk (lambda (self version start end proc)
                    (TextStore-for-each-chunk string-store-instance version start end proc)))
  (replace (lambda (self version start end text) (TextStore-replace string-store-instance version start end text))))

(defplugin (counting-text-store ctx)
  "Stores text as the toy text store does, counting how often lines are counted."
  provides: [text-store-service]
  (context-provide! ctx text-store-service (TextStore (make-counting-store))))

;; An object that refers to another: two of them can refer to each other.
(defstruct ring (other))

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
         (check (length (text-highlights-in t 1 (fx1+ (text-size t)))) => 2)
         (text-replace! t 6 8 "")         ; all of the first: it goes
         (check (length (text-highlights t 'digits)) => 1)
         (check (text-highlights t 'other) => [])))))

  (test-case "highlights: a ranged set replaces only what lies inside its range, clipped at its edges"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (let (t (current-text))
         (insert "0123456789abcdefghij")
         (set-highlights! t 'faces [(make-span 1 4 'a) (make-span 6 12 'b) (make-span 15 18 'c)])
         ;; 5..10: the span 6..12 keeps 10..12; a new span crossing 10 is
         ;; clipped to the range.
         (set-highlights! t 'faces [(make-span 7 13 'd)] start: 5 end: 10)
         (check (map (lambda (s) [(span-start s) (span-end s) (span-value s)]) (text-highlights t 'faces))
                => [[1 4 'a] [7 10 'd] [10 12 'b] [15 18 'c]])
         ;; A range inside one span splits it.
         (set-highlights! t 'faces [] start: 16 end: 17)
         (check (spans-of (text-highlights t 'faces)) => [[1 4] [7 10] [10 12] [15 16] [17 18]])
         ;; The whole text, by default.
         (set-highlights! t 'faces [(make-span 2 3 'e)])
         (check (spans-of (text-highlights t 'faces)) => [[2 3]])
         (check (raises? (lambda () (set-highlights! t 'faces [] start: 5 end: 99))) => #t)))))

  (test-case "highlights: the same spans in a range are no change; others are"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (let* ((t (current-text))
              (root (buffer-root (current-buffer))))
         (insert "ab12cd345")
         (set-highlights! t 'digits [(make-span 3 5 'digit) (make-span 7 10 'digit)])
         (let ((decoration (text-decoration-revision t))
               (revision (node-revision root)))
           ;; The same spans, as new objects, and the same part of them in a range.
           (set-highlights! t 'digits [(make-span 7 10 'digit) (make-span 3 5 'digit)])
           (set-highlights! t 'digits [(make-span 3 5 'digit)] start: 1 end: 6)
           (set-highlights! t 'other [])
           (check (text-decoration-revision t) => decoration)
           (check (node-revision root) => revision)
           (check (drawn-again? (lambda () (text-highlights t 'digits))
                                (lambda () (set-highlights! t 'digits [(make-span 3 5 'digit) (make-span 7 10 'digit)])))
                  => #f)
           (check (drawn-again? (lambda () (text-highlights t 'digits))
                                (lambda () (set-highlights! t 'digits [(make-span 3 5 'other)] start: 1 end: 6)))
                  => #t)
           (check (> (node-revision root) revision) => #t))))))

  (test-case "highlights: text-highlights-in finds exactly the spans overlapping a range, of every layer"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (let (t (current-text))
         (insert (make-string 100 #\x))
         ;; A long span early, then short ones.
         (set-highlights! t 'long [(make-span 2 90 'long)])
         (set-highlights! t 'short (map (lambda (i) (make-span i (+ i 2) 'short)) (iota 30 1 3)))
         (def (found start end)
           (list-sort span-pair<? (map (lambda (s) [(span-start s) (span-end s)]) (text-highlights-in t start end))))
         (def (expected start end)
           (list-sort span-pair<? (filter (lambda (se) (and (< (car se) end) (> (cadr se) start)))
                                          (cons [2 90] (map (lambda (i) [i (+ i 2)]) (iota 30 1 3))))))
         (for-each (lambda (range)
                     (check (found (car range) (cadr range)) => (expected (car range) (cadr range))))
                   [[1 2] [3 4] [10 20] [40 41] [89 95] [90 101] [95 96] [5 5]])
         ;; Edits move them, in order.
         (text-replace! t 1 1 "yy")
         (check (found 4 5) => [[3 5] [4 92]])))))

  (test-case "a job's ranged spans move past edits and replace only their moved range"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (let (t (current-text))
         (insert "a12b34c56")
         (set-highlights! t 'digits [(make-span 2 4 'digit) (make-span 5 7 'digit) (make-span 8 10 'digit)])
         (let ((target (JobTarget t))
               (revision (text-chars-revision t))
               ;; A job's result for 4..8, "b34c": the 34 only.
               (result (make-ranged-spans 4 8 [(make-span 5 7 'number)])))
           (text-replace! t 1 1 "xx")      ; everything moves by 2
           (text-replace! t 6 6 "!")       ; at the range's start: stays outside
           (check (text-string t) => "xxa12!b34c56")
           (match (JobTarget-job-rebase target result revision)
             ([(? ranged-spans? moved)]
              (check [(ranged-spans-start moved) (ranged-spans-end moved)] => [7 11])
              (check (spans-of (ranged-spans-spans moved)) => [[8 10]])
              (set-highlights! t 'digits (ranged-spans-spans moved)
                               start: (ranged-spans-start moved) end: (ranged-spans-end moved))
              (check (map (lambda (s) [(span-start s) (span-end s) (span-value s)]) (text-highlights t 'digits))
                     => [[4 6 'digit] [8 10 'number] [11 13 'digit]]))
             (else (check 'moved => 'not-moved)))
           ;; A range deleted whole leaves nothing to apply.
           (let (revision (text-chars-revision t))
             (text-replace! t 6 12 "")
             (check (JobTarget-job-rebase target (make-ranged-spans 7 11 []) revision) => #f)))))))

  (test-case "a line's token names nothing once the journal no longer reaches its revision"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (let* ((t (current-text))
              (root (buffer-root (current-buffer))))
         (insert "one\ntwo\nthree")
         (let (token (item-token (node-item-at root 1)))
           (check (item-line (token-item root token)) => 2)
           (for-each (lambda (_) (text-replace! t 1 1 "x")) (iota 1100))
           (check (token-item root token) => #f)
           (check (item-line (token-item root (item-token (node-item-at root 1)))) => 2))))))

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

  (test-case "a change gives its node and every node above it a new, larger revision"
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
             (check (> (cadr after) (cadr before)) => #t)
             (check (> (caddr after) (caddr before)) => #t)
             (check (cadddr after) => (cadddr before))))
         (let (before (revisions))
           (set-highlights! t 'digits [(make-span 1 2 'digit)])
           (check (> (node-revision root) (caddr before)) => #t)
           (check (node-revision other) => (cadddr before)))
         (let (before (node-revision root))
           (set-node-attribute! other 'label "Other")
           (check (node-attribute other 'label) => "Other")
           (check (> (node-revision other) before) => #t)
           (check (> (node-revision root) before) => #t)
           (check (> (node-revision root) (node-revision section)) => #t))
         (let (before (node-revision root))
           (set-node-children! section [])
           (check (> (node-revision root) before) => #t))))))

  (test-case "an attribute set to an equal value is no change: no revision"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (let* ((n (new-node 'item attributes: [(cons 'label "One") (cons 'size [1 2])]))
              (root (new-node 'root children: [n])))
         (let ((own (node-revision n))
               (revision (node-revision root)))
           (set-node-attribute! n 'label (string-append "O" "ne"))
           (set-node-attribute! n 'size [1 2])
           (check (node-revision n) => own)
           (check (node-revision root) => revision)
           ;; A new attribute, even #f, and a different value are changes.
           (set-node-attribute! n 'hidden #f)
           (check (> (node-revision root) revision) => #t)
           (let (revision (node-revision root))
             (set-node-attribute! n 'label "Two")
             (check (> (node-revision root) revision) => #t)
             (check (node-attribute n 'label) => "Two")))))))

  (test-case "sources: what is drawn from a node, text, buffer or view is drawn again when it changes"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (let* ((n (new-node 'item attributes: [(cons 'label "One")]))
              (root (new-node 'root children: [n]))
              (b (current-buffer))
              (v (selected-view))
              (t (current-text))
              (label (lambda () (node-attribute n 'label))))
         (check (drawn-again? label (lambda () (set-node-attribute! n 'label "One"))) => #f)
         (check (drawn-again? label (lambda () (set-node-attribute! n 'label "Two"))) => #t)
         (check (drawn-again? (lambda () (node-children root)) (lambda () (set-node-attribute! n 'size 1))) => #t)
         (insert "a\nb\nc")
         (check (drawn-again? (lambda () (text-substring t 1 2)) (lambda () (insert "x"))) => #t)
         (check (drawn-again? (lambda () (text-highlights-in t 1 2))
                              (lambda () (set-highlights! t 'faces [(make-span 1 2 'bold)])))
                => #t)
         (check (drawn-again? (lambda () (text-highlights-in t 1 2))
                              (lambda () (set-highlights! t 'faces [(make-span 1 2 'bold)])))
                => #f)
         (check (drawn-again? (lambda () (view-point v)) (lambda () (goto-char (point)))) => #f)
         (check (drawn-again? (lambda () (view-point v)) (lambda () (goto-char 1))) => #t)
         ;; Scrolling changes the view's placement, not what its buffer draws.
         (check (drawn-again? (lambda () (view-node v)) (lambda () (place-view! v #f 'top))) => #f)
         (check (drawn-again? (lambda () (view-showing v)) (lambda () (place-view! v #f 'top))) => #f)
         (check (drawn-again? (lambda () (view-placement v)) (lambda () (place-view! v #f 'top))) => #t)
         (check (drawn-again? (lambda () (buffer-local-value fill-width b))
                              (lambda () (set-buffer-setting! b fill-width 70)))
                => #t)
         (check (drawn-again? (lambda () (buffer-local-value fill-width b))
                              (lambda () (set-buffer-setting! b fill-width 70)))
                => #f)
         (check (drawn-again? (lambda () (buffer-name b)) (lambda () (rename-buffer! b "renamed"))) => #t)
         (check (drawn-again? selected-view (lambda () (set-selected-view! v))) => #f)))))

  (test-case "sources: an attribute holding objects is compared by identity, even when they are cyclic"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (let* ((ring (lambda ()
                      (let ((a (make-ring #f)) (b (make-ring #f)))
                        (set! (ring-other a) b)
                        (set! (ring-other b) a)
                        a)))
              (old (ring))
              (n (new-node 'item attributes: [(cons 'object old)]))
              (label (lambda () (node-attribute n 'object))))
         (check (drawn-again? label (lambda () (set-node-attribute! n 'object old))) => #f)
         (check (drawn-again? label (lambda () (set-node-attribute! n 'object (ring)))) => #t)))))

  (test-case "sources: client measurements count only when they differ once rounded"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (insert "a\nb\nc")
       (let* ((v (selected-view))
              (n (view-node v))
              (c (make-client "a"))
              (cv (view-client v c))
              (read (lambda () (view-client v c))))
         (set-client-view-average-item-height! cv 24.)
         (set-client-view-scroll! cv (node-item-at n 1) 3.)
         (check (drawn-again? read (lambda () (set-client-view-average-item-height! cv 24.004))) => #f)
         (check (client-view-average-item-height cv) => 24.)
         (check (drawn-again? read (lambda () (set-client-view-average-item-height! cv 24.5))) => #t)
         (check (drawn-again? read (lambda () (set-client-view-drawn-items! cv 200 200))) => #f)
         (check (drawn-again? read (lambda () (set-client-view-drawn-items! cv 10 10))) => #t)
         (check (drawn-again? read (lambda () (set-client-view-scroll! cv (node-item-at n 1) 3.2))) => #f)
         (check (drawn-again? read (lambda () (set-client-view-scroll! cv (node-item-at n 2) 3.2))) => #t)
         (check (drawn-again? read (lambda () (place-view! v (node-item-at n 0) 'top))) => #t)
         (check (drawn-again? read (lambda () (set-view-scroll! v c (node-item-at n 2) 0.))) => #t)
         (check (drawn-again? (lambda () (view-placement v)) (lambda () (set-view-scroll! v c (node-item-at n 1) 0.)))
                => #t)
         (check (drawn-again? (lambda () (view-point v) (client-view-scroll-item (view-client v c))) void) => #f)
         ;; Drawing never makes a client's view: it is made again first.
         (check (drawn-again? read (lambda () (forget-view-client! v c) (view-client v c))) => #t)))))

  (test-case "test mode: drawing may relocate point and a scroll item, but not make a client's view"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (insert "a\nb\nc")
       (let* ((v (selected-view))
              (n (view-node v))
              (cv (view-client v #f))
              (cache (new-memo-cache)))
         (set-client-view-scroll! cv (node-item-at n 2) 0.)
         (goto-char 1)
         (insert "new line\n")
         (check (memo-checking?) => #t)
         (check (call-with-memo-pass cache #f
                  (lambda () (memo 'p [] (lambda (i) [(view-point v) (item-line (client-view-scroll-item cv))]))))
                => [10 4])
         (check (raises? (lambda ()
                           (call-with-memo-pass cache #f
                             (lambda () (memo 'q [] (lambda (i) (view-client v (make-client "b"))))))))
                => #t)))))

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
           (check (> (node-revision root) before) => #t))
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
         (check (node-text-projection tree) => "\ntext")))))

  (test-case "items: a text opens into its lines, a node with children into theirs, any other node is one"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (defplugin (item-kinds ctx)
         "Defines a kind whose nodes are one item even with children."
         requires: [buffers-service]
         (context-define-node-kind! ctx 'card items: 'whole))
       (activate-plugin! item-kinds)
       (let* ((text (new-text-node (new-text "a\nb\nc")))
              (box (new-node 'box))
              (card (new-node 'card children: [(new-text-node (new-text "inside"))]))
              (empty (new-node 'column))
              (root (new-node 'column children: [box text empty card]))
              (index (lambda (it) (node-item-index root it))))
         (check (map node-opening [text box card empty root]) => '(lines whole whole whole children))
         (check (map node-item-count [text box card root]) => [3 1 1 6])
         (check (item-node (node-item-at root 0)) => box)
         (check (item-line (node-item-at root 2)) => 2)
         (check (item-node (node-item-at root 5)) => card)
         (check (raises? (lambda () (node-item-at root 6))) => #t)
         (check (map (lambda (i) (index (node-item-at root i))) [0 1 2 3 4 5]) => [0 1 2 3 4 5])
         (check (map (lambda (it) (node-item-index text it)) [(node-item-at text 2) (node-item box)]) => [2 #f])
         ;; A node inside a node that is one item is not an item.
         (check (index (node-item (car (node-children card)))) => #f)
         (check (map (lambda (child-start) [(node-id (car child-start)) (cdr child-start)])
                     (node-child-items root 2 5))
                => [[(node-id text) 1] [(node-id empty) 4] [(node-id card) 5]])))))

  (test-case "a node's items counted again after a change below one child count only that child again"
    (call-with-fresh-kernel [counting-text-store settings provider]
     (lambda ()
       (let* ((texts (map (lambda (k) (new-text "a\nb")) (iota 200)))
              (root (new-node 'column children: (map new-text-node texts))))
         (check (node-item-count root) => 400)
         (text-replace! (list-ref texts 7) 1 1 "x\n")
         (set! line-counts 0)
         (check (node-item-count root) => 401)
         (check line-counts => 1)
         (check (item-line (node-item-at root 16)) => 3)
         (check (node-item-index root (node-item-at root 300)) => 300)
         ;; Children replaced, reordered, added and removed.
         (let ((children (node-children root))
               (one (new-text-node (new-text "one"))))
           (set-node-children! root (cons one (reverse (cddr children))))
           ;; The child changed above has three lines.
           (check (node-item-count root) => (+ 1 (* 2 198) 1))
           (check (item-line (node-item-at root 0)) => 1)
           (check (eq? (item-node (node-item-at root 1)) (list-ref children 199)) => #t))))))

  (test-case "items keep their identity through edits around them; tokens name them"
    (call-with-fresh-kernel buffer-plugins
     (lambda ()
       (let* ((t (new-text "one\ntwo\nthree"))
              (text (new-text-node t))
              (row (new-node 'box))
              (root (new-node 'column children: [row text]))
              (three (node-item-at root 3))
              (token (item-token three)))
         (check (item-line three) => 3)
         (check (item=? (token-item root (item-token (node-item row))) (node-item row)) => #t)
         ;; Two lines inserted above: the item is line 5 now, and so is the
         ;; item the old token names.
         (text-replace! t 1 1 "zero\nhalf\n")
         (check (item-line three) => 5)
         (check (node-item-index root three) => 5)
         (check (item-line (token-item root token)) => 5)
         (check (item=? (token-item root token) three) => #t)
         (check (item=? (token-item root (item-token three)) three) => #t)
         ;; Deleting from inside the line before into it moves it to that
         ;; line's start, as a point there would.
         (text-replace! t (fx1+ (text-line-start t 4)) (fx1+ (text-line-start t 5)) "")
         (check (item-line three) => 4)
         (check (map (lambda (bad) (token-item root bad)) ["" "x" "1.2" "99999" "1.2.3.4" (item-token (node-item root))])
                => [#f #f #f #f #f #f])
         ;; A node no longer under the root is no item of it.
         (set-node-children! root [text])
         (check (node-item-index root (node-item row)) => #f)
         (check (token-item root (item-token (node-item row))) => #f)
         (check (node-item-count root) => 4))))))

(def buffers-test
  (test-suite "tuna/services/buffers: the default provider"
    (buffers-contract-cases buffers)

    (test-case "texts release detached subtrees and track them again on reattachment"
      (call-with-fresh-kernel [rope-text-store settings buffers]
        (lambda ()
          (let* ((t (new-text "shared"))
                 (root (new-node 'column)))
            (for-each (lambda (_)
                        (set-node-children! root
                          [(new-node 'column children: [(new-text-node t)])]))
                      (iota 1000))
            (check (length (slot-ref t 'nodes)) => 1)
            (let* ((branch (car (node-children root)))
                   (leaf (car (node-children branch))))
              (set-node-children! root [])
              (check (slot-ref t 'nodes) => [])
              (text-replace! t 1 1 "!")
              (let (revision (node-revision leaf))
                (set-node-children! root [branch])
                (check (> (node-revision leaf) revision) => #t))
              (check (slot-ref t 'nodes) => [leaf])
              (let (revision (node-revision root))
                (text-replace! t 1 1 "!")
                (check (> (node-revision root) revision) => #t)))))))

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
