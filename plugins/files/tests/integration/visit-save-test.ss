;;; Visiting and saving files through the files contract, on real files in
;;; a temporary folder.
(import :std/test
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/completion/contract
        :tuna/plugins/files/contract
        :tuna/plugins/commands/plugin :tuna/plugins/keys/plugin :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin :tuna/plugins/buffers/plugin :tuna/plugins/layout/plugin
        :tuna/plugins/minibuffer/plugin :tuna/plugins/completion/plugin
        :tuna/plugins/files/plugin
        (only-in :tuna/plugins/files/picker file-table)
        "../../../../tuna/tests/support/kernel"
        "../../../../plugins/session/tests/support/session"
        "../support/folder")
(export visit-save-test)

(def hook-calls [])
(def take-saves? #f)

(defplugin (save-observer ctx)
  "Records the save hooks, and takes saves over while take-saves? is on."
  requires: [files-service buffers-service]
  (context-add-hook! ctx before-save-hook 'observe
                     (lambda (b) (set! hook-calls (cons ['before (buffer-name b)] hook-calls))))
  (context-add-hook! ctx after-save-hook 'observe
                     (lambda (b) (set! hook-calls (cons ['after (buffer-name b)] hook-calls))))
  (context-add-save-takeover! ctx 'observe
    (lambda (b)
      (and take-saves?
           (begin
             (write-file-bytes (buffer-file b) (string->utf8 "taken over\n"))
             #t)))))

(defplugin (failing-before-save ctx)
  "A before-save callback that fails."
  requires: [files-service]
  (context-add-hook! ctx before-save-hook 'broken (lambda (b) (error "formatter broke"))))

(def messages [])

(defstruct message-list () final: #t)
(defmethod {message! message-list}
  (lambda (self text) (set! messages (cons text messages))))

(defplugin (all-messages ctx)
  "Keeps every message, newest first."
  provides: [messages-service]
  (context-provide! ctx messages-service (make-message-list)))

(def (current-message) => :string
  (if (pair? messages) (car messages) ""))

(def files-plugins
  [commands keys all-messages rope-text-store settings no-session buffers layout
   minibuffer completion files save-observer])

(def (with-files (proc : :procedure)) => :t
  (set! hook-calls [])
  (set! messages [])
  (set! take-saves? #f)
  (call-with-folder
   (lambda (folder)
     (call-with-fresh-kernel files-plugins
       (lambda ()
         (start-editor-loop!)
         (proc folder))))))

(def (on-editor (thunk : :procedure)) => :t (call-on-editor-loop thunk))

(def (text-of (b : buffer)) => text (text-node-content (buffer-root b)))

;; Insert STRING at POSITION of B's text.
(def (edit! (b : buffer) (position : :fixnum) (string : :string)) => :void
  (text-replace! (text-of b) position position string))

(def (mode-of (path : :string)) => :fixnum
  (fxand (file-info-mode (file-info path)) #o777))

(def (inode-of (path : :string)) => :integer
  (file-info-inode (file-info path)))

(def visit-save-test
  (test-suite "tuna/plugins/files: visiting and saving"
    (test-case "open, edit and save: the bytes change, the buffer is unsaved until saved, no temporary file stays"
      (with-files
       (lambda (folder)
         (let (path (string-append folder "a.txt"))
           (put-string! path "hello\n")
           (on-editor
            (lambda ()
              (let (b (find-file-noselect path))
                (check (buffer-name b) => "a.txt")
                (check (buffer-file b) => path)
                (check (text-string (text-of b)) => "hello\n")
                (check (buffer-local-value default-directory b) => folder)
                (check (buffer-modified? b) => #f)
                (edit! b 1 "well, ")
                (check (buffer-modified? b) => #t)
                (check (save-buffer b) => #t)
                (check (buffer-modified? b) => #f)
                (check (current-message) => (string-append "Wrote " (abbreviate-file-name path)))
                (check (eq? (find-file-noselect path) b) => #t))))
           (check (string-of path) => "well, hello\n")
           (check (folder-names folder) => ["a.txt"])))))
    (test-case "a byte-order mark and Windows line endings are written back byte for byte"
      (with-files
       (lambda (folder)
         (let (path (string-append folder "w.txt"))
           (put-bytes! path (u8vector-append (u8vector #xEF #xBB #xBF) (string->utf8 "one\r\ntwo\r\n")))
           (on-editor
            (lambda ()
              (let (b (find-file-noselect path))
                (check (text-string (text-of b)) => "one\ntwo\n")
                (edit! b 5 "2 ")
                (save-buffer b))))
           (check (bytes-of path) => (u8vector-append (u8vector #xEF #xBB #xBF) (string->utf8 "one\r\n2 two\r\n")))))))
    (test-case "mixed line endings and a missing final newline are kept"
      (with-files
       (lambda (folder)
         (let (path (string-append folder "m.txt"))
           (put-string! path "a\r\nb\nc")
           (on-editor
            (lambda ()
              (let (b (find-file-noselect path))
                (edit! b (fx1+ (text-size (text-of b))) "!")
                (save-buffer b))))
           (check (string-of path) => "a\r\nb\nc!")))))
    (test-case "invalid UTF-8 and binary files open read-only and are never saved"
      (with-files
       (lambda (folder)
         (let ((bad (string-append folder "bad.txt"))
               (binary (string-append folder "x.bin"))
               (bad-bytes (u8vector 104 105 #xFF 10))
               (binary-bytes (u8vector 127 69 76 70 0 1 2)))
           (put-bytes! bad bad-bytes)
           (put-bytes! binary binary-bytes)
           (on-editor
            (lambda ()
              (let (b (find-file-noselect bad))
                (check (current-message) => (string-append (abbreviate-file-name bad) " is not valid UTF-8; opened read-only"))
                (check (buffer-local-value buffer-read-only b) => #t)
                (set-view-buffer (selected-view) b)
                (check (with-catch (lambda (e) 'refused) (lambda () (insert "x") 'inserted)) => 'refused)
                (edit! b 1 "x")                 ; even a change by its owner is not saved
                (check (save-buffer b) => #f)
                (check (string-contains (current-message) "read-only") ? number?))
              (let (b (find-file-noselect binary))
                (check (string-contains (current-message) "binary") ? number?)
                (check (save-buffer b) => #f))))
           (check (bytes-of bad) => bad-bytes)
           (check (bytes-of binary) => binary-bytes)))))
    (test-case "a save replaces the file atomically and keeps its mode"
      (with-files
       (lambda (folder)
         (let (path (string-append folder "a.txt"))
           (put-string! path "x\n")
           (check (shell-command (string-append "chmod 640 " path)) => 0)
           (let (before (inode-of path))
             (on-editor (lambda () (let (b (find-file-noselect path)) (edit! b 1 "y") (save-buffer b))))
             (check (string-of path) => "yx\n")
             (check (mode-of path) => #o640)
             (check (eqv? (inode-of path) before) => #f)
             (check (folder-names folder) => ["a.txt"]))))))
    (test-case "a symbolic link saves through to its target and stays a link; both names are one text"
      (with-files
       (lambda (folder)
         (let ((real (string-append folder "real.txt"))
               (link (string-append folder "link.txt")))
           (put-string! real "r\n")
           (create-symbolic-link real link)
           (on-editor
            (lambda ()
              (let (b (find-file-noselect link))
                (check (eq? (find-file-noselect real) b) => #t)
                (check (length (file-buffers)) => 1)
                (edit! b 1 "s")
                (save-buffer b))))
           (check (file-info-type (file-info link #f)) => 'symbolic-link)
           (check (string-of real) => "sr\n")
           (check (folder-names folder) => ["link.txt" "real.txt"])))))
    (test-case "a file with hard links is written in place and keeps them"
      (with-files
       (lambda (folder)
         (let ((path (string-append folder "a.txt"))
               (other (string-append folder "b.txt")))
           (put-string! path "h\n")
           (create-link path other)
           (let (before (inode-of path))
             (on-editor (lambda () (let (b (find-file-noselect path)) (edit! b 1 "i") (save-buffer b))))
             (check (inode-of path) => before)
             (check (string-of other) => "ih\n")
             (check (file-info-number-of-links (file-info path)) => 2)
             (check (folder-names folder) => ["a.txt" "b.txt"]))))))
    (test-case "save hooks run in order; a takeover saves instead; a failing hook is reported and the save goes on"
      (with-files
       (lambda (folder)
         (let (path (string-append folder "h.txt"))
           (put-string! path "1\n")
           (on-editor
            (lambda ()
              (let (b (find-file-noselect path))
                (edit! b 1 "0")
                (save-buffer b)
                (check (reverse hook-calls) => [['before "h.txt"] ['after "h.txt"]])
                (set! take-saves? #t)
                (edit! b 1 "-")
                (check (save-buffer b) => #t)
                (check (buffer-modified? b) => #f))))
           (check (string-of path) => "taken over\n")
           (set! take-saves? #f)
           (on-editor (lambda () (activate-plugin! failing-before-save)))
           (on-editor
            (lambda ()
              (let (b (find-file-noselect path))
                (edit! b 1 "+")
                (check (save-buffer b) => #t)
                (check (ormap (lambda (m) (and (string-contains m "formatter broke") #t)) messages) => #t))))
           (check (string-of path) => "+-01\n")))))
    (test-case "a new name makes an empty buffer saved on first save; no folder is ever created"
      (with-files
       (lambda (folder)
         (let ((path (string-append folder "new.txt"))
               (deep (string-append folder "no/such/new.txt")))
           (on-editor
            (lambda ()
              (let (b (find-file-noselect path))
                (check (current-message) => "(New file)")
                (check (save-buffer b) => #t))
              (let (b (find-file-noselect deep))
                (edit! b 1 "x")
                (check (save-buffer b) => #f)
                (check (string-prefix? "Could not save new.txt<such>: No such folder; Tuna creates none" (current-message)) => #t)
                (check (buffer-modified? b) => #t))))
           (check (string-of path) => "")
           (check (folder-names folder) => ["new.txt"])))))
    (test-case "files with the same name are named after their folders; killing one renames the other"
      (with-files
       (lambda (folder)
         (create-directory (string-append folder "docs"))
         (create-directory (string-append folder "work"))
         (put-string! (string-append folder "docs/notes.txt") "d\n")
         (put-string! (string-append folder "work/notes.txt") "w\n")
         (on-editor
          (lambda ()
            (let* ((a (find-file-noselect (string-append folder "docs/notes.txt")))
                   (b (find-file-noselect (string-append folder "work/notes.txt"))))
              (check (buffer-name a) => "notes.txt<docs>")
              (check (buffer-name b) => "notes.txt<work>")
              (kill-buffer a)
              (check (buffer-name b) => "notes.txt")))))))
    (test-case "write-file makes a buffer visit a new file"
      (with-files
       (lambda (folder)
         (let (path (string-append folder "out.txt"))
           (on-editor
            (lambda ()
              (let (b (current-buffer))
                (edit! b 1 "scratch text")
                (check (write-file b path) => #t)
                (check (buffer-file b) => path)
                (check (buffer-name b) => "out.txt")
                (check (buffer-modified? b) => #f))))
           (check (string-of path) => "scratch text")))))
    (test-case "the picker's table lists the folder typed, folders with a /"
      (with-files
       (lambda (folder)
         (create-directory (string-append folder "sub"))
         (put-string! (string-append folder "b.txt") "")
         (put-string! (string-append folder "sub/c.txt") "")
         (on-editor
          (lambda ()
            (let* ((table (file-table folder))
                   (items (completion-table-items table)))
              (check (completion-table-category table) => 'file)
              (check (map candidate-text (items "")) => ["b.txt" "sub/"])
              (check (map candidate-value (items "")) => [(string-append folder "b.txt") (string-append folder "sub/")])
              (check (map candidate-text (items "sub/c")) => ["sub/c.txt"])
              (check (map candidate-text (items (string-append folder "sub/")))
                     => [(string-append folder "sub/c.txt")])))))))))
