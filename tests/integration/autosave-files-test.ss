;;; The autosave and files plugins together: an unsaved file buffer's text
;;; is autosaved in the state folder and comes back after a restart with
;;; its file; a file changed or deleted meanwhile comes back in conflict or
;;; unsaved; saving, killing, or editing back removes the copy. Each test
;;; uses its own state folder and a temporary folder of files.
prelude: :gerbil/core
(import :std/test
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/minibuffer/contract
        :tuna/plugins/session/contract
        :tuna/plugins/files/contract
        :tuna/plugins/commands/plugin :tuna/plugins/keys/plugin :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin :tuna/plugins/session/plugin :tuna/plugins/buffers/plugin
        :tuna/plugins/autosave/plugin :tuna/plugins/layout/plugin :tuna/plugins/view-commands/plugin
        :tuna/plugins/editing/plugin :tuna/plugins/minibuffer/plugin :tuna/plugins/renderer/plugin
        :tuna/plugins/completion/plugin :tuna/plugins/completion-list/plugin
        :tuna/plugins/files/plugin
        "../../tuna/tests/support/kernel" "../../tuna/tests/support/string-input"
        "../../plugins/keys/tests/support/keys"
        "../../plugins/files/tests/support/folder")
(export autosave-files-test)

(def autosave-files-plugins
  [commands keys test-messages rope-text-store settings session buffers autosave layout view-commands
   editing minibuffer html-renderer completion completion-list files])

;; Run THUNK in one run of Tuna keeping its state in STATE, booted as main
;; does: activate, restore, start the loop.
(def (run-tuna (state : :string) (thunk : :procedure)) => :t
  (call-with-fresh-kernel []
    (lambda ()
      (parameterize ((session-state-directory state))
        (for-each activate-plugin! autosave-files-plugins))
      (restore-session)
      (start-editor-loop!)
      (thunk))))

(def (on-editor (thunk : :procedure)) => :t (call-on-editor-loop thunk))

;; Call PROC with a state folder and a folder holding notes.txt with
;; Windows line endings, and its name.
(def (with-notes (proc : :procedure)) => :t
  (call-with-folder
   (lambda (state)
     (call-with-folder
      (lambda (folder)
        (let (path (string-append folder "notes.txt"))
          (put-string! path "one\r\ntwo\r\n")
          (proc state path)))))))

(def (notes) => (Maybe buffer) (get-buffer "notes.txt"))
(def (text-of (b : buffer)) => text (text-node-content (buffer-root b)))

;; The autosave copy of the file at PATH, in STATE.
(def (copy-of (state : :string) (path : :string)) => :string
  (path-expand (string-append "#" (autosave-file-name (on-editor (lambda () (true-name path)))) "#")
               (path-expand "autosave" state)))

;; Open PATH in the selected view, insert "new " at its start, and save
;; the session, as the idle save would.
(def (edit-and-autosave! (path : :string)) => :void
  (on-editor
   (lambda ()
     (let (b (find-file path))
       (text-replace! (text-of b) 1 1 "new ")
       (set-view-point! (selected-view) 5)
       (save-session)))))

(def (question) => (Maybe :string)
  (on-editor (lambda () (let (p (active-prompt)) (and p (prompt-display-question p))))))

(def autosave-files-test
  (test-suite "integration: autosave of file buffers"
    (test-case "an unsaved file buffer comes back after a restart with its file, unsaved, and saves with its line endings"
      (with-notes
       (lambda (state path)
         (run-tuna state
           (lambda ()
             (edit-and-autosave! path)
             (check (string-of (copy-of state path)) => "new one\ntwo\n")))
         (run-tuna state
           (lambda ()
             (on-editor
              (lambda ()
                (let (b (notes))
                  (check (buffer-file b) => path)
                  (check (text-string (text-of b)) => "new one\ntwo\n")
                  (check (buffer-point b) => 5)
                  (check (buffer-modified? b) => #t)
                  (check (visit-conflict? (buffer-visit b)) => #f)
                  (check (save-buffer b) => #t))))
             (check (bytes-of path) => (string->utf8 "new one\r\ntwo\r\n"))
             (check (file-exists? (copy-of state path)) => #f))))))
    (test-case "a file buffer without unsaved changes is read again from disk"
      (with-notes
       (lambda (state path)
         (run-tuna state
           (lambda ()
             (on-editor (lambda () (find-file path) (save-session)))
             (check (file-exists? (copy-of state path)) => #f)))
         (put-string! path "three\n")
         (run-tuna state
           (lambda ()
             (on-editor
              (lambda ()
                (let (b (notes))
                  (check (text-string (text-of b)) => "three\n")
                  (check (buffer-modified? b) => #f)))))))))
    (test-case "a file changed while Tuna was not running comes back in conflict; saving asks, o overwrites"
      (with-notes
       (lambda (state path)
         (run-tuna state (lambda () (edit-and-autosave! path)))
         (put-string! path "theirs\n")
         (run-tuna state
           (lambda ()
             (check (current-message) => "notes.txt changed on disk while Tuna was not running")
             (on-editor
              (lambda ()
                (let (b (notes))
                  (check (text-string (text-of b)) => "new one\ntwo\n")
                  (check (buffer-modified? b) => #t)
                  (check (visit-conflict? (buffer-visit b)) => #t)
                  (set-view-buffer (selected-view) b))))
             (type! "C-x" "C-s")
             (check (question)
                    => "notes.txt changed on disk; save anyway? [o]verwrite with yours, [r]eload theirs, C-g cancels ")
             (type! "o")
             (check (question) => #f)
             (check (bytes-of path) => (string->utf8 "new one\r\ntwo\r\n")))))))
    (test-case "a file deleted while Tuna was not running comes back unsaved with a note; saving writes it again"
      (with-notes
       (lambda (state path)
         (run-tuna state (lambda () (edit-and-autosave! path)))
         (delete-file path)
         (run-tuna state
           (lambda ()
             (check (current-message) => "notes.txt was deleted on disk while Tuna was not running")
             (on-editor
              (lambda ()
                (let (b (notes))
                  (check (text-string (text-of b)) => "new one\ntwo\n")
                  (check (buffer-modified? b) => #t)
                  (check (save-buffer b) => #t))))
             (check (bytes-of path) => (string->utf8 "new one\r\ntwo\r\n")))))))
    (test-case "saving, editing back, or killing the buffer removes its autosave copy"
      (with-notes
       (lambda (state path)
         (run-tuna state
           (lambda ()
             (edit-and-autosave! path)
             (let (copy (copy-of state path))
               (check (file-exists? copy) => #t)
               (on-editor (lambda () (save-buffer (notes))))
               (check (file-exists? copy) => #f)
               ;; Back to the saved text: gone at the next autosave.
               (on-editor (lambda () (text-replace! (text-of (notes)) 1 1 "x") (save-session)))
               (check (file-exists? copy) => #t)
               (on-editor (lambda () (text-replace! (text-of (notes)) 1 2 "") (save-session)))
               (check (file-exists? copy) => #f)
               (on-editor (lambda () (text-replace! (text-of (notes)) 1 1 "x") (save-session)))
               (check (file-exists? copy) => #t)
               (on-editor (lambda () (kill-buffer (notes)) (save-session)))
               (check (file-exists? copy) => #f)
               (check (string-of path) => "new one\r\ntwo\r\n"))))
         (run-tuna state
           (lambda ()
             (check (on-editor (lambda () (and (notes) #t))) => #f))))))))
