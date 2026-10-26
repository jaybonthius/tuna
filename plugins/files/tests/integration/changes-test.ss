;;; Changes on disk, through the files contract, on real files in a
;;; temporary folder, with real inotify (and polling where it is turned
;;; off): reloading an unchanged buffer by diff, ignoring changes that are
;;; none, marking a conflict, deletions, revert-buffer and its hooks.
(import :std/test
        :tuna/kernel
        :tuna/plugins/settings/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/files/contract
        :tuna/plugins/commands/plugin :tuna/plugins/keys/plugin :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin :tuna/plugins/buffers/plugin :tuna/plugins/layout/plugin
        :tuna/plugins/minibuffer/plugin :tuna/plugins/completion/plugin
        :tuna/plugins/files/plugin
        "../../../../tuna/tests/support/kernel"
        "../../../../plugins/session/tests/support/session"
        "../support/folder")
(export changes-test)

(def messages [])

(defstruct message-list () final: #t)
(defmethod {message! message-list}
  (lambda (self text) (set! messages (cons text messages))))

(defplugin (all-messages ctx)
  "Keeps every message, newest first."
  provides: [messages-service]
  (context-provide! ctx messages-service (make-message-list)))

(def revert-calls [])

(defplugin (revert-observer ctx)
  "Records the revert hooks."
  requires: [files-service buffers-service]
  (context-add-hook! ctx before-revert-hook 'observe
                     (lambda (b) (set! revert-calls (cons ['before (text-string (text-node-content (buffer-root b)))] revert-calls))))
  (context-add-hook! ctx after-revert-hook 'observe
                     (lambda (b) (set! revert-calls (cons ['after (text-string (text-node-content (buffer-root b)))] revert-calls)))))

(defplugin (slow-polling ctx)
  "Files are polled every 0.2 s instead of watched."
  requires: [settings-service]
  (context-set-setting! ctx auto-revert-use-notify #f)
  (context-set-setting! ctx auto-revert-interval .2))

(defplugin (no-polling ctx)
  "Files are neither watched nor polled in time: only a recheck sees changes."
  requires: [settings-service]
  (context-set-setting! ctx auto-revert-use-notify #f)
  (context-set-setting! ctx auto-revert-interval 600))

(def files-plugins
  [commands keys all-messages rope-text-store settings no-session buffers layout
   minibuffer completion files revert-observer])

(def (with-files (proc : :procedure) extra: (extra : :list := [])) => :t
  (set! messages [])
  (set! revert-calls [])
  (call-with-folder
   (lambda (folder)
     (call-with-fresh-kernel (append extra files-plugins)
       (lambda ()
         (start-editor-loop!)
         (proc folder))))))

(def (on-editor (thunk : :procedure)) => :t (call-on-editor-loop thunk))

(def (text-of (b : buffer)) => text (text-node-content (buffer-root b)))

(def (contents (b : buffer)) => :string (on-editor (lambda () (text-string (text-of b)))))

(def (said? (text : :string)) => :boolean (and (member text messages) #t))

;; Wait up to 5 s for (READY?) to be true; whether it became true.
(def (eventually (ready? : :procedure)) => :boolean
  (let lp ((left 100))
    (cond
     ((on-editor ready?) #t)
     ((fx= left 0) #f)
     (else (thread-sleep! .05) (lp (fx1- left))))))

;; Visit PATH in the selected view.
(def (open! (path : :string)) => buffer
  (on-editor (lambda () (find-file path))))

;; Write TEXT to PATH as programs that save by renaming do.
(def (put-by-rename! (path : :string) (text : :string)) => :void
  (let (temporary (string-append path ".tmp-other"))
    (put-string! temporary text)
    (rename-file temporary path)))

(def changes-test
  (test-suite "tuna/plugins/files: changes on disk"
    (test-case "another program overwriting an unchanged file reloads it, keeping the cursor, as one undo step"
      (with-files
       (lambda (folder)
         (let (path (string-append folder "notes.txt"))
           (put-string! path "one\ntwo\nthree\n")
           (let (b (open! path))
             (on-editor (lambda () (set-view-point! (selected-view) 11)))   ; the r of three
             (put-string! path "zero\none\ntwo\nthree\nfour\n")
             (check (eventually (lambda () (equal? (text-string (text-of b)) "zero\none\ntwo\nthree\nfour\n"))) => #t)
             (on-editor
              (lambda ()
                (check (view-point (selected-view)) => 16)
                (check (buffer-modified? b) => #f)
                (check (said? "Reloaded notes.txt") => #t)
                (check (reverse revert-calls) => [['before "one\ntwo\nthree\n"] ['after "zero\none\ntwo\nthree\nfour\n"]])
                (text-undo! (text-of b) #f)
                (check (text-string (text-of b)) => "one\ntwo\nthree\n")
                (check (buffer-modified? b) => #t))))))))
    (test-case "writing the same bytes again (touch) changes nothing"
      (with-files
       (lambda (folder)
         (let (path (string-append folder "same.txt"))
           (put-string! path "unchanged\n")
           (let* ((b (open! path))
                  (revision (on-editor (lambda () (text-chars-revision (text-of b))))))
             (thread-sleep! .05)
             (put-string! path "unchanged\n")
             (thread-sleep! 1.5)
             (on-editor
              (lambda ()
                (check (text-chars-revision (text-of b)) => revision)
                (check (said? "Reloaded same.txt") => #f)
                (check (said? "same.txt changed on disk") => #f))))))))
    (test-case "a save by writing a new file and renaming it over the old one is seen"
      (with-files
       (lambda (folder)
         (let (path (string-append folder "renamed.txt"))
           (put-string! path "before\n")
           (let (b (open! path))
             (put-by-rename! path "after\n")
             (check (eventually (lambda () (equal? (text-string (text-of b)) "after\n"))) => #t)
             ;; The folder is still watched after the rename.
             (put-by-rename! path "after again\n")
             (check (eventually (lambda () (equal? (text-string (text-of b)) "after again\n"))) => #t))))))
    (test-case "a buffer with unsaved changes is not reloaded but marked as in conflict"
      (with-files
       (lambda (folder)
         (let (path (string-append folder "mine.txt"))
           (put-string! path "base\n")
           (let (b (open! path))
             (on-editor (lambda () (text-replace! (text-of b) 1 1 "my ")))
             (put-string! path "theirs\n")
             (check (eventually (lambda () (said? "mine.txt changed on disk"))) => #t)
             (on-editor
              (lambda ()
                (check (text-string (text-of b)) => "my base\n")
                (check (visit-conflict? (buffer-visit b)) => #t)
                (check (buffer-modified? b) => #t))))))))
    (test-case "with auto-revert off, a changed file is not reloaded"
      (with-files
       (lambda (folder)
         (let (path (string-append folder "kept.txt"))
           (put-string! path "old\n")
           (let (b (open! path))
             (on-editor (lambda () (set-buffer-setting! b auto-revert #f)))
             (put-string! path "new\n")
             (check (eventually (lambda () (said? "kept.txt changed on disk"))) => #t)
             (check (contents b) => "old\n"))))))
    (test-case "a deleted file is reported after a moment and its buffer becomes unsaved; saving writes it again"
      (with-files
       (lambda (folder)
         (let (path (string-append folder "gone.txt"))
           (put-string! path "here\n")
           (let (b (open! path))
             (delete-file path)
             (check (eventually (lambda () (said? "gone.txt was deleted on disk"))) => #t)
             (on-editor
              (lambda ()
                (check (buffer-modified? b) => #t)
                (check (save-buffer b) => #t)))
             (check (string-of path) => "here\n"))))))
    (test-case "a file renamed away counts as deleted"
      (with-files
       (lambda (folder)
         (let (path (string-append folder "moved.txt"))
           (put-string! path "here\n")
           (let (b (open! path))
             (rename-file path (string-append folder "elsewhere.txt"))
             (check (eventually (lambda () (said? "moved.txt was deleted on disk"))) => #t))))))
    (test-case "a file deleted and quickly created again is a change, not a deletion"
      (with-files
       (lambda (folder)
         (let (path (string-append folder "back.txt"))
           (put-string! path "first\n")
           (let (b (open! path))
             (delete-file path)
             (put-string! path "second\n")
             (check (eventually (lambda () (equal? (text-string (text-of b)) "second\n"))) => #t)
             (thread-sleep! .5)
             (check (said? "back.txt was deleted on disk") => #f))))))
    (test-case "Tuna's own save sets off nothing"
      (with-files
       (lambda (folder)
         (let (path (string-append folder "own.txt"))
           (put-string! path "text\n")
           (let (b (open! path))
             (on-editor (lambda () (text-replace! (text-of b) 1 1 "more ") (save-buffer b)))
             (let (revision (on-editor (lambda () (text-chars-revision (text-of b)))))
               (thread-sleep! 1.5)
               (on-editor
                (lambda ()
                  (check (text-chars-revision (text-of b)) => revision)
                  (check (buffer-modified? b) => #f)
                  (check (visit-conflict? (buffer-visit b)) => #f)
                  (check (said? "Reloaded own.txt") => #f)
                  (check (said? "own.txt changed on disk") => #f)))))))))
    (test-case "where notifications are off, files are polled"
      (with-files
       (lambda (folder)
         (let (path (string-append folder "polled.txt"))
           (put-string! path "one\n")
           (let (b (open! path))
             (put-by-rename! path "two\n")
             (check (eventually (lambda () (equal? (text-string (text-of b)) "two\n"))) => #t))))
       extra: [slow-polling]))
    (test-case "check-watched-files looks at every file again"
      (with-files
       (lambda (folder)
         (let (path (string-append folder "missed.txt"))
           (put-string! path "one\n")
           (let (b (open! path))
             (thread-sleep! .3)
             (put-string! path "two\n")
             (thread-sleep! 1)
             (check (contents b) => "one\n")
             (on-editor check-watched-files)
             (check (eventually (lambda () (equal? (text-string (text-of b)) "two\n"))) => #t))))
       extra: [no-polling]))
    (test-case "revert-buffer reads the file again as one undoable change, running its hooks"
      (with-files
       (lambda (folder)
         (let (path (string-append folder "revert.txt"))
           (put-string! path "a\nb\nc\n")
           (let (b (open! path))
             (on-editor
              (lambda ()
                (set-buffer-setting! b auto-revert #f)
                (text-replace! (text-of b) 3 4 "B")
                (check (revert-buffer b) => #t)
                (check (text-string (text-of b)) => "a\nb\nc\n")
                (check (buffer-modified? b) => #f)
                (check (reverse revert-calls) => [['before "a\nB\nc\n"] ['after "a\nb\nc\n"]])))
             (on-editor
              (lambda ()
                (text-undo! (text-of b) #f)
                (check (text-string (text-of b)) => "a\nB\nc\n"))))))))
    (test-case "a buffer's revert-buffer-function replaces reading its file"
      (with-files
       (lambda (folder)
         (let (path (string-append folder "own-revert.txt"))
           (put-string! path "x\n")
           (let* ((b (open! path))
                  (called #f))
             (on-editor
              (lambda ()
                (set-buffer-setting! b revert-buffer-function (lambda (buffer) (set! called buffer)))
                (check (revert-buffer b) => #t)
                (check (eq? called b) => #t)
                (check revert-calls => []))))))))))
