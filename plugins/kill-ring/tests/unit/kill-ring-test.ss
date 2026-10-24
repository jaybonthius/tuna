;;; The kill-ring plugin through the real editor loop: killing, copying,
;;; yanking and yank-pop, with the mark set directly on the view.
(import :std/test
        :tuna/kernel
        :tuna/plugins/keys/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/region/contract
        :tuna/plugins/kill-ring/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/region/plugin
        :tuna/plugins/kill-ring/plugin
        "../../../../tuna/tests/support/kernel"
        "../../../keys/tests/support/keys"
        (only-in "../../../../tuna/tests/support/string-input" test-messages current-message))
(export kill-ring-test)

(def kill-ring-plugins
  [commands keys test-messages rope-text-store settings buffers region kill-ring])

;; The text, point, the mark, whether the region is active and the
;; message, once every key sent so far has run.
(def (state)
  (call-on-editor-loop
   (lambda ()
     (let (v (selected-view))
       [(text-string (current-text)) (point) (view-mark v) (region-active?) (current-message)]))))

;; Point at POINT and an active region to MARK.
(def (select! point mark)
  (call-on-editor-loop
   (lambda ()
     (let (v (selected-view))
       (goto-char point)
       (set-view-mark! v mark)
       (set-view-mark-active! v #t)))))

(def kill-ring-test
  (test-suite "tuna/plugins/kill-ring"
    (test-case "C-w kills the region and C-y yanks it back, with the mark before it"
      (call-with-fresh-kernel kill-ring-plugins
       (lambda ()
         (start-editor-loop!)
         (call-on-editor-loop (lambda () (insert "one two three")))
         (select! 4 1)
         (type! "C-w")
         (check (state) => [" two three" 1 1 #f ""])
         (call-on-editor-loop (lambda () (goto-char 11)))
         (type! "C-y")
         (check (state) => [" two threeone" 14 11 #f "Mark set"]))))

    (test-case "M-w copies and deactivates; M-y replaces a yank with older kills, and only after a yank"
      (call-with-fresh-kernel kill-ring-plugins
       (lambda ()
         (start-editor-loop!)
         (call-on-editor-loop (lambda () (insert "ab")))
         (select! 1 2)
         (type! "M-w")
         (check (state) => ["ab" 1 2 #f ""])
         (select! 3 2)
         (type! "M-w" "C-y")
         (check (state) => ["abb" 4 3 #f "Mark set"])
         (type! "M-y")
         (check (state) => ["aba" 4 3 #f ""])
         (type! "M-y")
         (check (state) => ["abb" 4 3 #f ""])
         (type! "C-g" "M-y")
         (check (state) => ["abb" 4 3 #f "Previous command was not a yank"]))))

    (test-case "putting a text on the ring runs kill-new-hook with it"
      (call-with-fresh-kernel kill-ring-plugins
       (lambda ()
         (let (seen [])
           (defplugin (watcher ctx) "Records killed texts."
             (context-add-hook! ctx kill-new-hook 'watcher (lambda (text) (set! seen (cons text seen)))))
           (activate-plugin! watcher)
           (kill-new "x")
           (check seen => ["x"])
           (check (current-kill 0) => "x")))))

    (test-case "a paste inserts its text at point and puts it on the kill ring, without copying it back; M-y replaces it"
      (call-with-fresh-kernel kill-ring-plugins
       (lambda ()
         (let (seen [])
           (defplugin (watcher ctx) "Records killed texts."
             (context-add-hook! ctx kill-new-hook 'watcher (lambda (text) (set! seen (cons text seen)))))
           (activate-plugin! watcher)
           (start-editor-loop!)
           (call-on-editor-loop (lambda () (insert "ab")))
           (select! 2 1)
           (type! "M-w")
           (paste "XY")
           (check (state) => ["aXYb" 4 2 #f "Mark set"])
           (check seen => ["a"])
           (check (call-on-editor-loop (lambda () (current-kill 0))) => "XY")
           (type! "M-y")
           (check (state) => ["aab" 3 2 #f ""])))))))
