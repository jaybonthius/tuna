;;; Selecting text from the keyboard with the real editing commands:
;;; shifted motion keys select, C-w and C-y move text through the kill
;;; ring, delete-selection makes yanking and pasting replace the region, and two views
;;; of one buffer keep their own marks. Selecting with the mouse: an
;;; unshifted motion key ends the selection a drag made, a shifted one
;;; extends it, and each step of a drag draws only the lines whose
;;; selected part changed.
(import :std/test
        :tuna/kernel
        :tuna/lib/memo
        :tuna/plugins/renderer/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/editing/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/layout/plugin
        :tuna/plugins/editing/plugin
        :tuna/plugins/renderer/plugin
        "../../tuna/tests/support/kernel"
        "../../plugins/keys/tests/support/keys"
        "../../plugins/session/tests/support/session"
        (only-in "../../tuna/tests/support/string-input" test-messages current-message))
(export selecting-text-test)

(defplugin (deleting-selection ctx)
  "Turns delete-selection on."
  requires: [settings-service]
  (context-set-setting! ctx delete-selection #t))

(def selecting-plugins
  [commands keys test-messages rope-text-store settings no-session buffers layout
   editing])

(def mouse-plugins
  (append selecting-plugins [html-renderer]))

;; A pointer event of KIND in the selected view at COLUMN of the line
;; holding POSITION, on a screen drawn now.
(def (point-at kind position column)
  (match (call-on-editor-loop
          (lambda ()
            (let (n (current-text-node))
              [(view-id (selected-view)) (node-id n) (item-token (node-line-item n position))
               (text-chars-revision (current-text))])))
    ([view node token revision]
     (click 'view view kind: kind node: node line: token line-revision: revision column: column))))

;; How many of the selected view's lines drawing a screen draws again.
(def (lines-drawn)
  (call-on-editor-loop
   (lambda ()
     (let ((keys [])
           (v (view-id (selected-view))))
       (parameterize ((current-memo-draw-observer (lambda (key) (set! keys (cons key keys)))))
         (html->string (Renderer-render-screen (Renderer (service-provider renderer-service)) #f)))
       (length (filter (lambda (key) (and (pair? key) (eq? (car key) 'line) (eqv? (cadr key) v))) keys))))))

;; The text, point, the mark and whether the region is active, once every
;; key sent so far has run.
(def (state)
  (call-on-editor-loop
   (lambda ()
     [(text-string (current-text)) (point) (view-mark (selected-view)) (region-active?)])))

(def selecting-text-test
  (test-suite "selecting text"
    (test-case "S-<down> selects a line, C-w kills it, C-y yanks it back elsewhere"
      (call-with-fresh-kernel selecting-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "a" "RET" "b" "RET" "c" "M-<")
         (type! "S-<down>")
         (check (state) => ["a\nb\nc" 3 1 #t])
         (type! "C-w")
         (check (state) => ["b\nc" 1 1 #f])
         (type! "M->" "RET" "C-y")
         (check (state) => ["b\nc\na\n" 7 5 #f]))))

    (test-case "with delete-selection on, yanking replaces the region"
      (call-with-fresh-kernel (append selecting-plugins [deleting-selection])
       (lambda ()
         (start-editor-loop!)
         (type! "a" "b" "c" "C-a" "S-<right>" "M-w" "C-e" "S-<left>" "S-<left>" "C-y")
         (check (state) => ["aa" 3 2 #f]))))

    (test-case "with delete-selection on, a paste replaces the region"
      (call-with-fresh-kernel (append selecting-plugins [deleting-selection])
       (lambda ()
         (start-editor-loop!)
         (type! "a" "b" "c" "S-<left>" "S-<left>")
         (paste "XY")
         (check (state) => ["aXY" 4 2 #f]))))

    (test-case "two views of one buffer keep their own marks"
      (call-with-fresh-kernel selecting-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "a" "b" "c" "d")
         (let* ((a (call-on-editor-loop selected-view))
                (b (call-on-editor-loop (lambda () (split-view a 'right)))))
           (type! "C-a" "C-SPC" "C-f")
           (call-on-editor-loop (lambda () (select-view b)))
           (type! "C-b" "C-SPC")
           (call-on-editor-loop (lambda () (select-view a)))
           (type! "C-a" "x")
           (check (call-on-editor-loop
                   (lambda () [(view-mark a) (view-mark-active? a) (view-mark b) (view-mark-active? b)]))
                  => [1 #f 5 #t])))))

    (test-case "an unshifted motion key ends a selection the mouse made; a shifted one extends it"
      (call-with-fresh-kernel mouse-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "a" "b" "c" "d" "e")
         (point-at 'down 1 1)
         (point-at 'movement 1 3)
         (point-at 'drag 1 3)
         (check (state) => ["abcde" 4 2 #t])
         (type! "S-<right>")
         (check (state) => ["abcde" 5 2 #t])
         (type! "C-b")
         (check (state) => ["abcde" 4 2 #f]))))

    (test-case "each step of a drag draws only the lines whose selected part changed"
      (call-with-fresh-kernel mouse-plugins
       (lambda ()
         (start-editor-loop!)
         (call-on-editor-loop (lambda () (insert "one\ntwo\nthree\nfour\n")))
         (point-at 'down 1 1)
         (lines-drawn)
         ;; Into line 2: line 1 is now selected from the press, and line 2
         ;; gets the cursor and its first character.
         (point-at 'movement 5 1)
         (check (lines-drawn) => 2)
         ;; Within line 2: that line only.
         (point-at 'movement 5 2)
         (check (lines-drawn) => 1)
         ;; Down to line 4: line 2 to its newline, line 3, and line 4's cursor.
         (point-at 'movement 15 0)
         (check (lines-drawn) => 3)
         ;; The release where the last movement was draws nothing again.
         (point-at 'drag 15 0)
         (check (lines-drawn) => 0)
         (check (state) => ["one\ntwo\nthree\nfour\n" 15 2 #t]))))))

