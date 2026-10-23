;;; Selecting text from the keyboard with the real editing commands:
;;; shifted motion keys select, C-w and C-y move text through the kill
;;; ring, delete-selection makes yanking replace the region, and two views
;;; of one buffer keep their own marks.
(import :std/test
        :tuna/kernel
        :tuna/plugins/settings/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/region/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/layout/plugin
        :tuna/plugins/basic-editing/plugin
        :tuna/plugins/region/plugin
        :tuna/plugins/kill-ring/plugin
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
   basic-editing region kill-ring])

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
                  => [1 #f 5 #t])))))))
