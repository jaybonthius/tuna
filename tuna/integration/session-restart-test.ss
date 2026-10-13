;;; Integration: a restart through the session and autosave plugins while
;;; the whole editor runs. Typing, renaming, windows swapped live and moved
;;; between, then a simulated restart, with the real keys, editing, window
;;; and rendering plugins. tuna/plugins/session-test.ss tests the session
;;; and autosave plugins alone.
(import :std/test
        :tuna/kernel
        :tuna/services/buffers
        :tuna/services/session
        :tuna/services/windows
        :tuna/plugins/keys
        :tuna/plugins/echo-area
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/session
        :tuna/plugins/buffers
        :tuna/plugins/autosave
        :tuna/plugins/single-window
        :tuna/plugins/window-commands
        :tuna/plugins/html-renderer
        :tuna/plugins/basic-editing
        "../test-support/kernel"
        "../test-support/keys"
        "../test-support/swap-commands")
(export session-restart-test)

(def (call-with-state-directory proc)
  (let (directory (path-expand (string-append "tuna-session-restart-test-"
                                              (number->string (random-integer 1000000000)))
                               (getenv "TMPDIR" "/tmp")))
    (create-directory* directory)
    (try
     (proc directory)
     (finally
      (delete-file-or-directory directory #t)))))

(def editor-plugins
  [keys-plugin echo-area-plugin rope-text-store-plugin settings-plugin
   session-plugin buffers-plugin autosave-plugin single-window-plugin window-commands-plugin
   html-renderer-plugin basic-editing-plugin swap-commands-plugin])

;; One run of Tuna on DIRECTORY, booted as main does: activate, restore,
;; start the loop.
(def (run-tuna directory thunk)
  (call-with-fresh-kernel []
    (lambda ()
      (parameterize ((session-state-directory directory))
        (for-each activate-plugin! editor-plugins))
      (restore-session)
      (start-editor-loop!)
      (thunk))))

(def (on-baton thunk) (call-on-editor-loop thunk))

(def (windows-state)
  (on-baton
   (lambda ()
     (map (lambda (w)
            (let (v (window-view w))
              [(buffer-name (view-showing v)) (view-point v)]))
          (window-list)))))

(def (buffer-text name)
  (on-baton
   (lambda ()
     (let (b (get-buffer name))
       (and b (text-string (text-node-content (first-text-node (buffer-root b)))))))))

(def (file-text path)
  (call-with-input-file [path: path char-encoding: 'UTF-8]
    (lambda (port)
      (let (content (read-line port #f))
        (if (eof-object? content) "" content)))))

(def (read-session-datum directory)
  (call-with-input-file [path: (path-expand "session.ss" directory) char-encoding: 'UTF-8] read))

(def session-restart-test
  (test-suite "integration: a session restart"
    (test-case "buffers, their text and names, and points come back after a restart"
      (call-with-state-directory
       (lambda (directory)
         (run-tuna directory
           (lambda ()
             (type! "h" "i" "1" "RET" "t" "h" "é" "r" "e" "😀" "C-p" "C-a" "C-f")
             (on-baton (lambda ()
                         (rename-buffer! (current-buffer) "notes")
                         (let (b (new-buffer "other" (new-text-node (new-text "another text"))))
                           (add-buffer! b)
                           (set-buffer-point! b 4))))
             (on-baton save-session)))
         (check (list-sort string<? (directory-files (path-expand "autosave" directory)))
                => ["notes" "other"])
         (check (file-text (path-expand "autosave/notes" directory)) => "hi1\nthére😀")
         (run-tuna directory
           (lambda ()
             (check (on-baton (lambda () (map buffer-name (buffer-list))))
                    => ["*scratch*" "notes" "other"])
             (check (buffer-text "notes") => "hi1\nthére😀")
             (check (buffer-text "other") => "another text")
             (check (on-baton (lambda () (buffer-point (get-buffer "other")))) => 4)
             (check (windows-state) => [["notes" 2]])
             ;; Typing goes on where it left off; the restored text is not undoable.
             (type! "X")
             (check (buffer-text "notes") => "hXi1\nthére😀")
             (type! "C-/" "C-/")
             (check (buffer-text "notes") => "hi1\nthére😀"))))))

    (test-case "a session saved with two windows restores the selected one under one window"
      (call-with-state-directory
       (lambda (directory)
         (run-tuna directory
           (lambda ()
             (type! "a" "b" "c" "C-c" "w" "C-b" "C-b" "C-x" "o")
             (check (windows-state) => [["*scratch*" 2] ["*scratch*" 4]])
             (on-baton save-session)))
         (check (assq 'windows (cddr (read-session-datum directory)))
                => ['windows 1 [['selected 1] ['windows ["*scratch*" 2] ["*scratch*" 4]]]])
         (run-tuna directory
           (lambda ()
             (check (windows-state) => [["*scratch*" 4]])
             (check (buffer-text "*scratch*") => "abc"))))))))
