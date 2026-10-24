#lang :tuna/prelude
;;; The hungry-delete demo through real Commands, Keys, Buffers and editing.
(import :std/test
        :tuna/kernel
        :tuna/plugins/commands/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/editing/plugin
        "../hungry-delete"
        "../../tuna/tests/support/kernel"
        "../../plugins/keys/tests/support/keys"
        (only-in "../../tuna/tests/support/string-input" test-messages current-message))
(export hungry-delete-test)

(def hungry-plugins
  [commands keys test-messages rope-text-store settings buffers editing hungry-delete])

(def (state) => :list
  (call-on-editor-loop
   (lambda () [(text-string (current-text)) (point) (current-message)])))

(def (show-text! (contents : :string)) => :void
  (let (b (new-buffer "test" (new-text-node (new-text contents))))
    (add-buffer! b)
    (switch-to-buffer b)
    (goto-char (point-max))))

(def (hungry-layers) => :list
  (map advice-info-owner
       (advice-target-info-advice (advice-for (command-target 'delete-backward-char)))))

(def hungry-delete-test
  (test-suite "tuna/demo/hungry-delete"
    (test-case "a run of spaces is one edit, and one undo restores text and point"
      (call-with-fresh-kernel hungry-plugins
       (lambda ()
         (show-text! "a   z")
         (goto-char 5)
         (start-editor-loop!)
         (type! "DEL")
         (check (state) => ["az" 2 ""])
         (type! "C-/")
         (check (state) => ["a   z" 5 "Undo"]))))

    (test-case "anything but a space falls through to one-character deletion"
      (for-each
       (lambda ((contents : :string))
         (call-with-fresh-kernel hungry-plugins
          (lambda ()
            (show-text! contents)
            (start-editor-loop!)
            (type! "DEL")
            (check (state) => ["a" 2 ""]))))
       ["ab" "a\t" "a\n"]))

    (test-case "turning the plugin off restores one-character Backspace"
      (call-with-fresh-kernel hungry-plugins
       (lambda ()
         (show-text! "a   ")
         (start-editor-loop!)
         (call-on-editor-loop (lambda () (deactivate-plugin! hungry-delete)))
         (type! "DEL")
         (check (state) => ["a  " 4 ""])
         (call-on-editor-loop
          (lambda ()
            ;; The editing plugin's delete-selection advice stays.
            (check (hungry-layers) => '(editing))
            (activate-plugin! hungry-delete)))
         (type! "DEL")
         (check (state) => ["a" 2 ""]))))

    (test-case "the advice stays while editing goes away and comes back"
      (call-with-fresh-kernel hungry-plugins
       (lambda ()
         (show-text! "a   ")
         (deactivate-plugin! editing)
         (check (command-entry 'delete-backward-char) => #f)
         (check (hungry-layers) => '(hungry-delete))
         (activate-plugin! editing)
         (start-editor-loop!)
         (type! "DEL")
         (check (state) => ["a" 2 ""]))))))
