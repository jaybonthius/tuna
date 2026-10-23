;;; The region plugin through the real editor loop: the mark commands,
;;; transient-mark rules, shift selection and delete-selection, with
;;; stand-ins for the motion and editing commands it reacts to.
(import :std/test
        :tuna/kernel
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/region/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/region/plugin
        "../../../../tuna/tests/support/kernel"
        "../../../keys/tests/support/keys"
        (only-in "../../../../tuna/tests/support/string-input" test-messages current-message))
(export region-test)

;; Stand-ins, under the names the region plugin knows: a motion, typing,
;; and deleting.
(defplugin (stand-ins ctx)
  "Binds <right> to forward-char, letters to self-insert-command and DEL to delete-backward-char."
  requires: [commands-service input-service buffers-service]
  (define-command ctx (forward-char) "Move one character forward."
    (goto-char (+ (point) 1)))
  (define-command ctx (self-insert-command) "Insert the key."
    (insert (key-event-key (last-command-event))))
  (define-command ctx (delete-backward-char) "Delete the character before point."
    (delete-region (- (point) 1) (point)))
  (keymap-set ctx "<right>" 'forward-char)
  (keymap-set ctx "C-f" 'forward-char)
  (keymap-set ctx printing-char-key 'self-insert-command)
  (keymap-set ctx "DEL" 'delete-backward-char))

(defplugin (deleting-selection ctx)
  "Turns delete-selection on."
  requires: [settings-service]
  (context-set-setting! ctx delete-selection #t))

(def region-plugins
  [commands keys test-messages rope-text-store settings buffers stand-ins region])

;; The text, point, the mark, whether the region is active and the
;; message, once every key sent so far has run.
(def (state)
  (call-on-editor-loop
   (lambda ()
     (let (v (selected-view))
       [(text-string (current-text)) (point) (view-mark v) (region-active?) (current-message)]))))

(def region-test
  (test-suite "tuna/plugins/region"
    (test-case "C-SPC sets the mark, C-x C-x swaps it with point, C-g and an edit deactivate"
      (call-with-fresh-kernel region-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "a" "b" "c" "d")
         (call-on-editor-loop (lambda () (goto-char 2)))
         (type! "C-SPC")
         (check (state) => ["abcd" 2 2 #t "Mark set"])
         (type! "<right>" "<right>")
         (check (state) => ["abcd" 4 2 #t ""])
         (check (call-on-editor-loop (lambda () [(region-beginning) (region-end)])) => [2 4])
         (type! "C-x" "C-x")
         (check (state) => ["abcd" 2 4 #t ""])
         (type! "C-g")
         (check (state) => ["abcd" 2 4 #f "Quit"])
         (type! "C-x" "C-x")
         (check (state) => ["abcd" 4 2 #t ""])
         (type! "x")
         (check (state) => ["abcxd" 5 2 #f ""])
         (type! "C-SPC" "C-SPC")
         (check (state) => ["abcxd" 5 5 #f "Mark deactivated"]))))

    (test-case "shifted motion selects; an unshifted one ends that region, but not one C-SPC made"
      (call-with-fresh-kernel region-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "a" "b" "c" "d")
         (call-on-editor-loop (lambda () (goto-char 1)))
         (type! "S-<right>" "C-F")
         (check (state) => ["abcd" 3 1 #t ""])
         (check (call-on-editor-loop this-command-keys-shift-translated?) => #f)
         (type! "<right>")
         (check (state) => ["abcd" 4 1 #f ""])
         (type! "C-SPC" "<right>")
         (check (state) => ["abcd" 5 4 #t ""]))))

    (test-case "with delete-selection on, typing and DEL replace the active region"
      (call-with-fresh-kernel (append region-plugins [deleting-selection])
       (lambda ()
         (start-editor-loop!)
         (type! "a" "b" "c" "d")
         (call-on-editor-loop (lambda () (goto-char 1)))
         (type! "S-<right>" "S-<right>" "x")
         (check (state) => ["xcd" 2 1 #f ""])
         (type! "S-<right>" "DEL")
         (check (state) => ["xd" 2 2 #f ""])
         ;; An empty region is not deleted: DEL deletes a character.
         (type! "C-SPC" "DEL")
         (check (state) => ["d" 1 1 #f ""]))))

    (test-case "two views of one buffer keep their own marks, which move with edits"
      (call-with-fresh-kernel region-plugins
       (lambda ()
         (insert "hello world")
         (let* ((a (selected-view))
                (b (copy-view a)))
           (set-view-mark! a 7)
           (set-view-mark! b 2)
           (goto-char 1)
           (insert ">>")
           (check [(view-mark a) (view-mark b)] => [9 4])
           (set-view-mark-active! a #t)
           (check [(view-mark-active? a) (view-mark-active? b)] => [#t #f])))))))
