;;; The text-mouse plugin through the real editor loop: a click in a line
;;; of text selects the view and moves its point to the column clicked,
;;; shifted through edits made after the screen was drawn; a column past
;;; the line's end goes to its end, a click below the text to the text's
;;; end, and a click on a line that is gone says so.
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
              (check (state left right) => [0 5 #\newline "Stale click: the line is gone (clicked on screen 0)"])))))))))
