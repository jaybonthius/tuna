;;; The editing plugin's word commands in a prompt: the minibuffer's
;;; answer is a text node edited by the same commands, so M-DEL in the
;;; file picker (C-x C-f) deletes a word of the name typed.
prelude: :gerbil/core
(import :std/test
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/editing/contract
        :tuna/plugins/completion/contract
        :tuna/plugins/files/contract
        :tuna/plugins/commands/plugin :tuna/plugins/keys/plugin :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin :tuna/plugins/buffers/plugin :tuna/plugins/layout/plugin
        :tuna/plugins/view-commands/plugin :tuna/plugins/editing/plugin
        :tuna/plugins/minibuffer/plugin :tuna/plugins/renderer/plugin
        :tuna/plugins/completion/plugin :tuna/plugins/completion-list/plugin
        :tuna/plugins/files/plugin
        "../../tuna/tests/support/kernel" "../../tuna/tests/support/string-input"
        "../../plugins/keys/tests/support/keys" "../../plugins/session/tests/support/session"
        "../../plugins/files/tests/support/folder")
(export editing-words-test)

(def picker-plugins
  [commands keys test-messages rope-text-store settings no-session buffers layout view-commands
   editing minibuffer html-renderer completion completion-list files])

(def (on-editor (thunk : :procedure)) => :t (call-on-editor-loop thunk))

(def (input) => :string (on-editor (lambda () (CompletionSession-session-input (current-completion-session)))))

(def editing-words-test
  (test-suite "editing's word commands in a prompt"
    (test-case "M-DEL in the file picker kills the last word of the name; M-b and M-f move over words; C-y yanks it back"
      (call-with-folder
       (lambda (folder)
         (call-with-fresh-kernel picker-plugins
           (lambda ()
             (start-editor-loop!)
             (on-editor (lambda () (set-buffer-setting! (current-buffer) default-directory folder)))
             (type! "C-x" "C-f")
             (check (input) => folder)
             (type! "s" "u" "b" "/" "n" "e" "w" "." "t" "x" "t")
             (type! "M-DEL")
             (check (input) => (string-append folder "sub/new."))
             (type! "M-DEL")
             (check (input) => (string-append folder "sub/"))
             (check (on-editor (lambda () (current-kill 0))) => "new.txt")
             (type! "M-b")
             (check (on-editor point) => (fx1+ (string-length folder)))
             (type! "M-f" "C-e" "C-y")
             (check (input) => (string-append folder "sub/new.txt"))
             (type! "C-g"))))))))
