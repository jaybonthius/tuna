;;; The files plugin through its keys: the picker (C-x C-f) with its ~/
;;; key, saving (C-x C-s, C-x s), the unsaved marker in the status
;;; line, and C-x k asking before killing an unsaved file buffer.
prelude: :gerbil/core
(import :std/test
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/renderer/contract
        :tuna/plugins/minibuffer/contract
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
(export files-test)

(def files-plugins
  [commands keys test-messages rope-text-store settings no-session buffers layout view-commands
   editing minibuffer html-renderer completion completion-list files])

(def (on-editor (thunk : :procedure)) => :t (call-on-editor-loop thunk))

;; Run PROC with a temporary folder holding a.txt, b.txt and sub/c.txt,
;; the current buffer's folder.
(def (with-picker (proc : :procedure)) => :t
  (call-with-folder
   (lambda (folder)
     (put-string! (string-append folder "a.txt") "alpha\n")
     (put-string! (string-append folder "b.txt") "beta\n")
     (create-directory (string-append folder "sub"))
     (put-string! (string-append folder "sub/c.txt") "")
     (call-with-fresh-kernel files-plugins
       (lambda ()
         (start-editor-loop!)
         (on-editor (lambda () (set-buffer-setting! (current-buffer) default-directory folder)))
         (proc folder))))))

(def (input) => :string (on-editor (lambda () (CompletionSession-session-input (current-completion-session)))))
(def (texts) => :list
  (on-editor (lambda () (map candidate-text (CompletionSession-session-candidates (current-completion-session))))))
(def (question) => (Maybe :string)
  (on-editor (lambda () (let (p (active-prompt)) (and p (prompt-display-question p))))))
(def (shown-buffer) => :string (on-editor (lambda () (buffer-name (current-buffer)))))
(def (screen) => :string
  (on-editor (lambda () (html->string (Renderer-render-screen (Renderer (service-provider renderer-service)) #f)))))
(def (contains? (text : :string) (part : :string)) => :boolean (and (string-contains text part) #t))

(def (type-string! (s : :string)) => :void
  (for-each (lambda (c) (press (if (char=? c #\space) "SPC" (string c)))) (string->list s)))

(def files-test
  (test-suite "files through their keys"
    (test-case "the picker lists the folder; DEL deletes one character; ~/ jumps home"
      (with-picker
       (lambda (folder)
         (type! "C-x" "C-f")
         (check (question) => "Find file: ")
         (check (input) => folder)
         ;; Completion's default order: shorter first, then by name.
         (check (texts) => [(string-append folder "sub/") (string-append folder "a.txt") (string-append folder "b.txt")])
         (type-string! "sub/")
         (check (input) => (string-append folder "sub/"))
         (check (texts) => [(string-append folder "sub/c.txt")])
         (type! "DEL")
         (check (input) => (string-append folder "sub"))
         (type-string! "/~/")
         (check (input) => "~/")
         (type! "DEL")
         (check (input) => "~")
         (type! "C-g")
         (check (question) => #f))))
    (test-case "C-x C-f opens the file chosen; editing marks it unsaved; C-x C-s saves it"
      (with-picker
       (lambda (folder)
         (type! "C-x" "C-f")
         (type-string! "a.t")
         (check (texts) => [(string-append folder "a.txt")])
         (check (contains? (screen) "completion-file-size") => #t)
         (type! "RET")
         (check (shown-buffer) => "a.txt")
         (check (contains? (screen) "a.txt · line") => #t)
         (type! "x")
         (check (contains? (screen) "a.txt * · line") => #t)
         (type! "C-x" "C-s")
         (check (contains? (screen) "a.txt · line") => #t)
         (check (string-of (string-append folder "a.txt")) => "xalpha\n")
         ;; The picker marks it open.
         (type! "C-x" "C-f")
         (type-string! "a.t")
         (check (contains? (screen) ">open<") => #t)
         (type! "C-g"))))
    (test-case "a new name in the picker makes a new file on its first save"
      (with-picker
       (lambda (folder)
         (type! "C-x" "C-f")
         (type-string! "fresh.md")
         (check (texts) => [])
         (type! "RET")
         (check (shown-buffer) => "fresh.md")
         (type! "h" "i" "C-x" "C-s")
         (check (shown-buffer) => "fresh.md")
         (check (string-of (string-append folder "fresh.md")) => "hi"))))
    (test-case "C-x k asks before killing an unsaved file buffer"
      (with-picker
       (lambda (folder)
         (type! "C-x" "C-f")
         (type-string! "b.t")
         (type! "RET" "y")
         (type! "C-x" "k" "RET")
         (check (question) => "Buffer b.txt modified; kill anyway? (yes or no) ")
         (type-string! "no")
         (type! "RET")
         (check (question) => #f)
         (check (shown-buffer) => "b.txt")
         (type! "C-x" "k" "RET")
         (type-string! "yes")
         (type! "RET")
         (check (on-editor (lambda () (and (get-buffer "b.txt") #t))) => #f)
         (check (string-of (string-append folder "b.txt")) => "beta\n"))))
    (test-case "C-x k kills a saved file buffer without asking"
      (with-picker
       (lambda (folder)
         (type! "C-x" "C-f")
         (type-string! "b.t")
         (type! "RET" "C-x" "k" "RET")
         (check (question) => #f)
         (check (on-editor (lambda () (and (get-buffer "b.txt") #t))) => #f))))
    (test-case "C-x s asks for each unsaved file: y saves, n skips"
      (with-picker
       (lambda (folder)
         (type! "C-x" "C-f")
         (type-string! "a.t")
         (type! "RET" "1")
         (type! "C-x" "C-f")
         (type-string! "b.t")
         (type! "RET" "2")
         (type! "C-x" "s")
         (check (question) => (string-append "Save file " (abbreviate-file-name folder) "a.txt? (y, n, !, ., q) "))
         (type! "y")
         (check (question) => (string-append "Save file " (abbreviate-file-name folder) "b.txt? (y, n, !, ., q) "))
         (type! "n")
         (check (question) => #f)
         (check (string-of (string-append folder "a.txt")) => "1alpha\n")
         (check (string-of (string-append folder "b.txt")) => "beta\n"))))))
