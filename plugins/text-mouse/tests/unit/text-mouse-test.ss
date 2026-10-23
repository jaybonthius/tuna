;;; The text-mouse plugin through the real editor loop: a click in a line
;;; of text selects the view and moves its point to the column clicked,
;;; shifted through edits made after the screen was drawn; a column past
;;; the line's end goes to its end, a click below the text to the text's
;;; end, and a click on a line that is gone says so. Pressing, dragging
;;; and releasing select; a double click selects a word and a triple
;;; click a line; shift-click extends the selection.
(import :std/test
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/layout/plugin
        :tuna/plugins/region/plugin
        :tuna/plugins/text-mouse/plugin
        "../../../../tuna/tests/support/kernel"
        "../../../keys/tests/support/keys"
        "../../../session/tests/support/session"
        (only-in "../../../../tuna/tests/support/string-input" test-messages current-message))
(export text-mouse-test)

(def text-mouse-plugins
  [commands keys test-messages rope-text-store settings no-session buffers layout region text-mouse])

;; Put TEXT in the selected view's text, point at its start, and split
;; the view: returns the two views, the text node's id and the text's
;; revision, as a screen drawn now would name them.
(def (two-views! text)
  (call-on-editor-loop
   (lambda ()
     (insert text)
     (goto-char 1)
     (let* ((left (selected-view))
            (right (split-view left 'right)))
       [left right (node-id (view-node left)) (text-chars-revision (current-text))]))))

;; The token of the line of the selected view's text holding POSITION, as
;; a screen drawn now names it.
(def (line-token position)
  (call-on-editor-loop (lambda () (item-token (node-line-item (current-text-node) position)))))

;; Which view is selected (0 for LEFT, 1 for RIGHT), its point, the
;; character after point and the message.
(def (state left right)
  (call-on-editor-loop
   (lambda ()
     (let* ((v (selected-view))
            (t (text-node-content (view-node v)))
            (p (view-point v)))
       [(if (eq? v left) 0 (if (eq? v right) 1 #f))
        p
        (and (fx<= p (text-size t)) (string-ref (text-substring t p (fx1+ p)) 0))
        (current-message)]))))

;; The selected view's point, mark, whether its region is active, and
;; the region's text.
(def (selection)
  (call-on-editor-loop
   (lambda ()
     (let* ((v (selected-view))
            (t (text-node-content (view-node v)))
            (p (view-point v))
            (m (view-mark v)))
       [p m (view-mark-active? v) (if m (text-substring t (min p m) (max p m)) "")]))))

;; A pointer event of KIND in view V at COLUMN of the line holding
;; POSITION, on a screen drawn now.
(def (point-at kind v node position column clicks: (clicks 1) shift?: (shift? #f))
  (click 'view (view-id v) kind: kind clicks: clicks shift?: shift? node: node
         line: (line-token position) column: column
         line-revision: (call-on-editor-loop (lambda () (text-chars-revision (current-text))))))

(def (edit! start end replacement)
  (call-on-editor-loop (lambda () (text-replace! (current-text) start end replacement))))

(def text-mouse-test
  (test-suite "tuna/plugins/text-mouse"
    (test-case "a click in a line selects its view, moves its point to the column clicked and deactivates the region"
      (call-with-fresh-kernel text-mouse-plugins
       (lambda ()
         (start-editor-loop!)
         (match (two-views! "hello\nworld\n")
           ([left right node revision]
            (call-on-editor-loop
             (lambda ()
               (set-view-mark! right 1)
               (set-view-mark-active! right #t)))
            (click 'view (view-id right) node: node line: (line-token 7) line-revision: revision column: 3)
            (check (state left right) => [1 10 #\l ""])
            (check (call-on-editor-loop (lambda () (view-mark-active? right))) => #f)
            (check (call-on-editor-loop (lambda () (view-point left))) => 1)
            ;; A line is named by any position in it, as the renderer names
            ;; lines by where they ended when first drawn.
            (click 'view (view-id left) node: node line: (line-token 6) line-revision: revision column: 1)
            (check (state left right) => [0 2 #\e ""]))))))

    (test-case "a click on a screen drawn before edits lands on the character clicked"
      (call-with-fresh-kernel text-mouse-plugins
       (lambda ()
         (start-editor-loop!)
         (match (two-views! "hello\nworld\n")
           ([left right node born]
            ;; The line was first drawn at BORN, ending at 12; it was drawn
            ;; again after "wo" became "WO!", then two characters were
            ;; inserted before the column clicked.
            (let (token (string-append (number->string node) ".12." (number->string born)))
              (edit! 7 9 "WO!")
              (let (drawn (call-on-editor-loop (lambda () (text-chars-revision (current-text)))))
                (edit! 8 8 "++")
                ;; Column 4 was the "l" of "WO!rld".
                (click 'view (view-id right) node: node line: token line-revision: drawn column: 4)
                (check (state left right) => [1 13 #\l ""])
                ;; An earlier line that grew by a newline moves the click down.
                (edit! 1 1 "new\n")
                (click 'view (view-id right) node: node line: token line-revision: drawn column: 4)
                (check (state left right) => [1 17 #\l ""]))))))))

    (test-case "a column past the line's end goes to its end, a click below the text to the text's end"
      (call-with-fresh-kernel text-mouse-plugins
       (lambda ()
         (start-editor-loop!)
         (match (two-views! "hello\nworld")
           ([left right node revision]
            (click 'view (view-id left) node: node line: (line-token 1) line-revision: revision column: 6)
            (check (state left right) => [0 6 #\newline ""])
            (click 'view (view-id left) node: node line: (line-token 7) line-revision: revision column: 99)
            (check (state left right) => [0 12 #f ""])
            ;; The same past an edit: the end of the line then, moved.
            (let (token (line-token 1))
              (edit! 1 1 "ab")
              (click 'view (view-id left) node: node line: token line-revision: revision column: 9)
              (check (state left right) => [0 8 #\newline ""]))
            (click 'view (view-id right))
            (check (state left right) => [1 14 #f ""]))))))

    (test-case "a click on a line that is gone says so and moves nothing"
      (call-with-fresh-kernel text-mouse-plugins
       (lambda ()
         (start-editor-loop!)
         (match (two-views! "one\ntwo\nthree\nfour")
           ([left right node revision]
            (let (token (line-token 5))
              (edit! 5 9 "")
              (click 'view (view-id left) node: node line: token line-revision: revision column: 1 revision: 4)
              (check (state left right) => [0 1 #\o "Stale click: the line is gone (clicked on screen 4)"]))
            ;; A line of a node that is not in the view's buffer.
            (click 'view (view-id left) node: node line: "99999.1.0" line-revision: 0 column: 1)
            (check (state left right) => [0 1 #\o "Stale click: the line is gone (clicked on screen 0)"])
            ;; Emptying a line keeps it: its newline is still there.
            (let ((token (line-token 5))
                  (emptied (call-on-editor-loop (lambda () (text-chars-revision (current-text))))))
              (edit! 5 10 "")
              (click 'view (view-id left) node: node line: token line-revision: emptied column: 2)
              (check (state left right) => [0 5 #\newline "Stale click: the line is gone (clicked on screen 0)"])))))))

    (test-case "pressing, dragging and releasing selects the text dragged over"
      (call-with-fresh-kernel text-mouse-plugins
       (lambda ()
         (start-editor-loop!)
         (match (two-views! "hello world\nsecond line\n")
           ([left right node revision]
            (point-at 'down right node 1 2)
            ;; The press moves point and leaves the region inactive.
            (check (state left right) => [1 3 #\l ""])
            (check (caddr (selection)) => #f)
            (point-at 'movement right node 13 3)
            (check (selection) => [16 3 #t "llo world\nsec"])
            ;; Dragging back over the press selects backwards.
            (point-at 'movement right node 1 0)
            (check (selection) => [1 3 #t "he"])
            (point-at 'drag right node 1 8)
            (check (selection) => [9 3 #t "llo wo"])
            ;; A movement after the release moves nothing.
            (point-at 'movement right node 13 1)
            (check (selection) => [9 3 #t "llo wo"]))))))

    (test-case "a press released where it was pressed is a click, keeping the mark; a drag back to it too"
      (call-with-fresh-kernel text-mouse-plugins
       (lambda ()
         (start-editor-loop!)
         (match (two-views! "hello world\nsecond line\n")
           ([left right node revision]
            (call-on-editor-loop (lambda () (set-view-mark! left 5)))
            (point-at 'down left node 1 7)
            (point-at 'click left node 1 7)
            (check (selection) => [8 5 #f "o w"])
            (point-at 'down left node 1 2)
            (point-at 'movement left node 1 4)
            (point-at 'drag left node 1 2)
            (check (selection) => [3 3 #f ""]))))))

    (test-case "a double click selects a word, a triple click a line with its newline"
      (call-with-fresh-kernel text-mouse-plugins
       (lambda ()
         (start-editor-loop!)
         (match (two-views! "hello world, done\nsecond line\n")
           ([left right node revision]
            (point-at 'down left node 1 8)
            (point-at 'click left node 1 8)
            (point-at 'down left node 1 8 clicks: 2)
            ;; The second press already selects the word.
            (check (selection) => [12 7 #t "world"])
            (point-at 'click left node 1 8 clicks: 2)
            (check (selection) => [12 7 #t "world"])
            (point-at 'down left node 1 8 clicks: 3)
            (point-at 'click left node 1 8 clicks: 3)
            (check (selection) => [19 1 #t "hello world, done\n"])
            ;; Whitespace and punctuation are runs of their own.
            (point-at 'click left node 1 12 clicks: 2)
            (check (selection) => [14 13 #t " "])
            (point-at 'click left node 1 10 clicks: 2)
            (check (selection) => [12 7 #t "world"])
            (point-at 'click left node 1 11 clicks: 2)
            (check (selection) => [13 12 #t ","])
            ;; The second line.
            (point-at 'click left node 19 2 clicks: 3)
            (check (selection) => [31 19 #t "second line\n"])
            ;; A double press dragged selects by words.
            (point-at 'down left node 1 1 clicks: 2)
            (point-at 'movement left node 1 8)
            (check (selection) => [12 1 #t "hello world"])
            (point-at 'drag left node 1 8 clicks: 2)
            (check (selection) => [12 1 #t "hello world"]))))))

    (test-case "shift-click extends the region from the mark when active, from point otherwise"
      (call-with-fresh-kernel text-mouse-plugins
       (lambda ()
         (start-editor-loop!)
         (match (two-views! "hello world\nsecond line\n")
           ([left right node revision]
            (point-at 'down left node 1 2)
            (point-at 'click left node 1 2)
            (point-at 'down left node 1 5 shift?: #t)
            (point-at 'click left node 1 5 shift?: #t)
            (check (selection) => [6 3 #t "llo"])
            ;; Again, from the same mark, now backwards.
            (point-at 'down left node 1 0 shift?: #t)
            (point-at 'click left node 1 0 shift?: #t)
            (check (selection) => [1 3 #t "he"])
            ;; Shift-dragging moves the same end.
            (point-at 'down left node 13 1 shift?: #t)
            (point-at 'movement left node 13 3)
            (check (selection) => [16 3 #t "llo world\nsec"])
            (point-at 'drag left node 13 4 shift?: #t)
            (check (selection) => [17 3 #t "llo world\nseco"]))))))

    (test-case "a drag released outside the text ends where the last movement put point"
      (call-with-fresh-kernel text-mouse-plugins
       (lambda ()
         (start-editor-loop!)
         (match (two-views! "hello world\nsecond line\n")
           ([left right node revision]
            (point-at 'down left node 1 1)
            (point-at 'movement left node 1 4)
            (click 'view (view-id left) kind: 'drag node: node)
            (check (selection) => [5 2 #t "ell"])
            (check (current-message) => ""))))))))

