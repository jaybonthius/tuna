;;; Basic editing driven by key events through the real editor loop.
(import :std/test
        :tuna/kernel
        :tuna/services/keys
        :tuna/services/buffers
        :tuna/services/echo-area
        :tuna/plugins/keys
        :tuna/plugins/echo-area
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/buffers
        :tuna/plugins/basic-editing)
(export basic-editing-test)

(def editing-commands
  '(self-insert-command newline delete-backward-char delete-char forward-char
    backward-char next-line previous-line move-beginning-of-line move-end-of-line undo))

(def editing-keys
  ["<printing-char>" "SPC" "RET" "DEL" "C-d" "C-f" "C-b" "C-n" "C-p" "C-a" "C-e"
   "<left>" "<right>" "<up>" "<down>" "C-/" "C-_"])

(include "test-keys.ss")

(def (with-editor thunk)
  (call-with-editor [keys-plugin echo-area-plugin rope-text-store-plugin settings-plugin
                     buffers-plugin basic-editing-plugin]
                    thunk))

;; The focused text and point once every key sent so far has run.
(def (state)
  (call-on-editor-loop
   (lambda () [(text-string (current-text)) (point) (current-message)])))

(def basic-editing-test
  (test-suite "tuna/plugins/basic-editing"
    (test-case "typing, deleting, and moving in *scratch*"
      (with-editor
       (lambda ()
         (type! "a" "é" "😀" "SPC" "b" "RET" "c" "d")
         (check (state) => ["aé😀 b\ncd" 9 ""])
         (type! "<up>")
         (check (state) => ["aé😀 b\ncd" 3 ""])
         (type! "C-e")
         (check (state) => ["aé😀 b\ncd" 6 ""])
         (type! "C-b" "C-b")
         (check (state) => ["aé😀 b\ncd" 4 ""])
         (type! "DEL")
         (check (state) => ["aé b\ncd" 3 ""])
         (type! "C-a" "C-d")
         (check (state) => ["é b\ncd" 1 ""])
         (type! "C-f" "C-n")
         (check (state) => ["é b\ncd" 6 ""])
         (type! "<right>" "<right>")
         (check (state) => ["é b\ncd" 7 "End of buffer"])
         (type! "C-p" "C-p")
         (check (state) => ["é b\ncd" 1 "Beginning of buffer"]))))

    (test-case "line motion keeps the goal column across short lines"
      (with-editor
       (lambda ()
         (type! "a" "b" "c" "d" "e" "RET" "x" "RET" "a" "b" "c" "d" "e" "C-b")
         (check (state) => ["abcde\nx\nabcde" 13 ""])
         (type! "C-p")
         (check (state) => ["abcde\nx\nabcde" 8 ""])
         (type! "C-p")
         (check (state) => ["abcde\nx\nabcde" 5 ""]))))

    (test-case "undo undoes typing as one group, other commands one at a time; after another command it redoes"
      (with-editor
       (lambda ()
         (type! "a" "b" "c" "DEL")
         (check (state) => ["ab" 3 ""])
         (type! "C-/")
         (check (state) => ["abc" 4 "Undo"])
         (type! "C-_")
         (check (state) => ["" 1 "Undo"])
         (type! "C-/")
         (check (state) => ["" 1 "No further undo information"])
         (type! "C-f" "C-/")
         (check (state) => ["abc" 4 "Undo"]))))

    (test-case "consecutive self-inserts group in twenties"
      (with-editor
       (lambda ()
         (for-each (lambda (_) (type! "x")) (iota 25))
         (type! "C-/")
         (check (state) => [(make-string 20 #\x) 21 "Undo"]))))

    (test-case "undoing a forward delete puts point back before the restored text"
      (with-editor
       (lambda ()
         (type! "a" "b" "C-a" "C-d")
         (check (state) => ["b" 1 ""])
         (type! "C-/")
         (check (state) => ["ab" 1 "Undo"]))))

    (test-case "turning basic editing off and on leaves no stray commands or keys"
      (with-editor
       (lambda ()
         (call-on-editor-loop
          (lambda ()
            (deactivate-plugin! basic-editing-plugin)
            (check (filter command-ref editing-commands) => [])
            (check (filter key-binding editing-keys) => [])
            (activate-plugin! basic-editing-plugin)
            (check (length (filter command-ref editing-commands)) => (length editing-commands))
            (check (length (filter key-binding editing-keys)) => (length editing-keys))
            (check (entry-source (key-binding "C-f")) ? string?)))
         (type! "x")
         (check (state) => ["x" 2 ""]))))))
