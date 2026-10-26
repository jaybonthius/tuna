;;; Recent files and remembered places, kept in the session's slots across
;;; restarts: each run of Tuna is a fresh kernel on the same state folder,
;;; booted as the program does (activate, restore the session, start the
;;; loop), with real files in a temporary folder.
(import :std/test
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/minibuffer/contract
        :tuna/plugins/completion/contract
        :tuna/plugins/session/contract
        :tuna/plugins/files/contract
        :tuna/plugins/commands/plugin :tuna/plugins/keys/plugin :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin :tuna/plugins/session/plugin :tuna/plugins/buffers/plugin
        :tuna/plugins/layout/plugin :tuna/plugins/editing/plugin :tuna/plugins/minibuffer/plugin
        :tuna/plugins/completion/plugin
        :tuna/plugins/files/plugin
        "../../../../tuna/tests/support/kernel"
        (only-in "../../../../tuna/tests/support/string-input" test-messages)
        "../../../../plugins/keys/tests/support/keys"
        "../support/folder")
(export remembering-test)

(defplugin (three-recent-files ctx)
  "Remembers three recent files."
  requires: [settings-service]
  (context-set-setting! ctx recent-files-limit 3))

(def remembering-plugins
  [commands keys test-messages rope-text-store settings session buffers layout editing
   minibuffer completion files three-recent-files])

;; One run of Tuna keeping its state in STATE.
(def (run-tuna (state : :string) (thunk : :procedure)) => :t
  (call-with-fresh-kernel []
    (lambda ()
      (parameterize ((session-state-directory state))
        (for-each activate-plugin! remembering-plugins))
      (restore-session)
      (start-editor-loop!)
      (thunk))))

;; FOLDER, the files' folder, and STATE, Tuna's state folder, both empty.
(def (with-folders (proc : :procedure)) => :t
  (call-with-folder
   (lambda (folder)
     (call-with-folder
      (lambda (state) (proc folder state))))))

(def (on-editor (thunk : :procedure)) => :t (call-on-editor-loop thunk))

(def (type-string! (s : :string)) => :void
  (for-each (lambda (c) (press (if (char=? c #\space) "SPC" (string c)))) (string->list s)))

(def (texts) => :list
  (on-editor (lambda () (map candidate-text (CompletionSession-session-candidates (current-completion-session))))))

;; The group titles of the candidates, in order, each run of one title once.
(def (titles) => :list
  (on-editor
   (lambda ()
     (let (s (current-completion-session))
       (reverse (foldl (lambda ((c : candidate) (out : :list))
                         (let (title (CompletionSession-session-group s c))
                           (if (and (pair? out) (equal? (car out) title)) out (cons title out))))
                       [] (CompletionSession-session-candidates s)))))))

(def (question) => (Maybe :string)
  (on-editor (lambda () (let (p (active-prompt)) (and p (prompt-display-question p))))))

;; The files recent-file offers.
(def (recent-texts) => :list
  (type! "M-x")
  (type-string! "recent-file")
  (type! "RET")
  (let (shown (texts))
    (type! "C-g")
    shown))

(def (open! (path : :string)) => :void
  (on-editor (lambda () (find-file path))))

(def (point-now) => :fixnum (on-editor point))

(def remembering-test
  (test-suite "tuna/plugins/files: recent files and remembered places"
    (test-case "recent files: most recent first, one per true name, capped, kept across a restart, missing ones dropped"
      (with-folders
       (lambda (folder state)
         (for-each (lambda (name) (put-string! (string-append folder name) "text\n"))
                   ["a.txt" "b.txt" "c.txt" "d.txt"])
         (create-symbolic-link (string-append folder "a.txt") (string-append folder "link.txt"))
         (let (file (lambda (name) (abbreviate-file-name (string-append folder name))))
           (run-tuna state
             (lambda ()
               (for-each (lambda (name) (open! (string-append folder name))) ["a.txt" "b.txt" "c.txt"])
               ;; The link is a.txt again, by its true name.
               (open! (string-append folder "link.txt"))
               (check (recent-texts) => [(file "a.txt") (file "c.txt") (file "b.txt")])
               (check (question) => #f)
               (open! (string-append folder "d.txt"))
               (check (recent-texts) => [(file "d.txt") (file "a.txt") (file "c.txt")])
               (on-editor save-session)))
           (run-tuna state
             (lambda ()
               (check (recent-texts) => [(file "d.txt") (file "a.txt") (file "c.txt")])
               (delete-file (string-append folder "a.txt"))
               (check (recent-texts) => [(file "d.txt") (file "c.txt")])))))))
    (test-case "the picker offers recent files first, then the folder; another folder shows only its files"
      (with-folders
       (lambda (folder state)
         (put-string! (string-append folder "a.txt") "alpha\n")
         (put-string! (string-append folder "b.txt") "beta\n")
         (create-directory (string-append folder "sub"))
         (put-string! (string-append folder "sub/c.txt") "")
         (run-tuna state
           (lambda ()
             (open! (string-append folder "sub/c.txt"))
             (open! (string-append folder "a.txt"))
             (type! "C-x" "C-f")
             (check (question) => "Find file: ")
             (check (texts) => [(string-append folder "a.txt") (string-append folder "sub/c.txt")
                                (string-append folder "sub/") (string-append folder "a.txt")
                                (string-append folder "b.txt")])
             (check (titles) => ["Recent files" "This folder"])
             ;; Recent files match the name typed after the folder.
             (type-string! "c.t")
             (check (texts) => [(string-append folder "sub/c.txt")])
             (check (titles) => ["Recent files"])
             (type! "DEL" "DEL" "DEL")
             (type-string! "sub/")
             (check (texts) => [(string-append folder "sub/c.txt")])
             (check (titles) => ["This folder"])
             (type! "C-g"))))))
    (test-case "remembered places: reopening a file puts the cursor back, clamped, also after a restart"
      (with-folders
       (lambda (folder state)
         (let ((a (string-append folder "a.txt")) (b (string-append folder "b.txt")))
           (put-string! a "one two three\n")
           (put-string! b "four five\n")
           (run-tuna state
             (lambda ()
               (open! a)
               (on-editor (lambda () (goto-char 5)))
               (on-editor (lambda () (kill-buffer (current-buffer))))
               (open! a)
               (check (point-now) => 5)
               (on-editor (lambda () (goto-char 9)))
               (open! b)
               (on-editor (lambda () (goto-char 8)))
               ;; Saving the session keeps the open buffers' places too.
               (on-editor save-session)))
           (put-string! b "four\n")
           (run-tuna state
             (lambda ()
               (open! a)
               (check (point-now) => 9)
               (open! b)
               (check (point-now) => 6)))))))))
