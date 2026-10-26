;;; The files contract (live tier; ADR 5): reading and writing files, and
;;; texts that visit them.
;;;
;;; All file access goes through the file service (`FileSystem`), whose
;;; provider is the local disk, so remote or compressed files can come
;;; later without touching its callers (Emacs's file-name handlers). Paths
;;; it takes are absolute and expanded (`expand-file-name`). It also
;;; watches files for changes by other programs.
;;;
;;; A text visits a file, not a buffer: its visit record says which file,
;;; what was on disk at the last read or save (its attributes and a hash of
;;; its bytes), how the bytes became characters (encoding, byte-order mark,
;;; line endings, final newline) and the text's character revision then.
;;; One text visits each file, found by true name or by device and inode,
;;; so a file reached through a symbolic link is still one text. Visiting
;;; makes a buffer showing the text (named after the file, with its
;;; folder's name added as "notes.txt<docs>" when two files share a name).
;;;
;;; Only UTF-8, with or without a byte-order mark, is editable. Windows
;;; line endings used on every line are shown as plain lines and written
;;; back; mixed line endings stay in the text as they are. Anything else
;;; (invalid UTF-8, UTF-16, binary) opens read-only and cannot be saved.
;;;
;;; When another program changes a visited file, a text with no unsaved
;;; changes is reloaded (the `auto-revert` setting), as one undoable change
;;; that replaces only the lines that changed; a text with unsaved changes
;;; is marked as in conflict, and saving it asks whether to overwrite the
;;; file or reload it. A file deleted or renamed away leaves its text
;;; unsaved, so saving writes it again.
;;;
;;; A file buffer's unsaved text can be kept elsewhere (the autosave plugin
;;; keeps it in Tuna's state folder) with its `buffer-recovery-data`, and
;;; `recover-file-buffer` makes the buffer again after a restart: visiting
;;; the file, holding the text unsaved, and in conflict when the file
;;; changed on disk meanwhile.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/lib/memo
        :tuna/plugins/settings/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract)
(export (struct-out file-stat folder-entry)
        (interface-out FileSystem)
        file-system-service
        stat-file read-file-bytes write-file-bytes list-folder true-name
        watch-file unwatch-file check-watched-files
        visit visit? visit-file-name visit-true-name visit-identity visit-disk visit-hash
        visit-encoding visit-bom? visit-line-ending visit-final-newline? visit-saved-revision visit-saved-size
        visit-conflict visit-conflict? visit-editable? visit-changes
        (interface-out Files)
        files-service
        find-file-noselect find-file
        text-visit buffer-visit buffer-file buffer-modified? file-buffers
        save-buffer write-file revert-buffer
        buffer-recovery-data recover-file-buffer
        find-file-hook auto-mode-hook before-save-hook after-save-hook
        before-revert-hook after-revert-hook
        auto-revert auto-revert-use-notify auto-revert-interval revert-buffer-function
        save-takeover-hook context-add-save-takeover! run-save-takeovers
        default-directory buffer-default-directory
        home-directory expand-file-name abbreviate-file-name
        file-name-directory file-name-nondirectory file-name-as-directory)

;;; The file service

;; What is at a path, following symbolic links: KIND is 'file, 'folder or
;; 'other; MODIFIED is nanoseconds since 1970; IDENTITY is (device . inode).
(defstruct file-stat ((kind     : :symbol)
                      (size     : :integer)
                      (modified : :integer)
                      (mode     : :fixnum)
                      (owner    : :fixnum)
                      (group    : :fixnum)
                      (links    : :fixnum)
                      (identity : :pair))
  final: #t)

;; One name in a folder and what is there.
(defstruct folder-entry ((name : :string)
                         (stat : file-stat))
  final: #t)

(interface FileSystem
  ;; What is at PATH, or #f when nothing is.
  (stat-file (path : :string)) => :t
  (read-file-bytes (path : :string)) => :u8vector
  ;; Make PATH hold BYTES, creating the file but never a folder. A crash
  ;; leaves the old contents or the new, never a mix; a symbolic link stays
  ;; a link and its target changes; the file keeps its identity, mode and
  ;; owner. Returns what is at PATH afterwards.
  (write-file-bytes (path : :string) (bytes : :u8vector)) => :t
  ;; The entries of folder PATH, without "." and "..", in no order.
  (list-folder (path : :string)) => :list
  ;; PATH with every symbolic link, "." and ".." resolved; for a file that
  ;; does not exist, its folder's true name and its name.
  (true-name (path : :string)) => :string
  ;; Call (CHANGED HASH) on the editor thread soon after another program
  ;; changed what is at PATH (a true name): wrote, replaced, created,
  ;; deleted or renamed it. HASH is the SHA-256 of the file's bytes then,
  ;; or #f when it is not a readable file. A file whose bytes did not
  ;; change (touch) is no change, but a replaced file with the same bytes
  ;; may be reported. Watching PATH again replaces CHANGED.
  (watch-file (path : :string) (changed : :procedure)) => :void
  (unwatch-file (path : :string)) => :void
  ;; Look at every watched file again soon, as when changes may have been
  ;; missed. Callable from any thread.
  (check-watched-files) => :void)

(def file-system-service
  (new-service 'file-system is-FileSystem? tier: 'live
               doc: "Reads, writes and lists files."))

(def (stat-file (path : :string)) => (Maybe file-stat)
  (:? (with-service-provider (provider file-system-service FileSystem) (FileSystem-stat-file provider path)) file-stat))

(def (read-file-bytes (path : :string)) => :u8vector
  (:- (with-service-provider (provider file-system-service FileSystem) (FileSystem-read-file-bytes provider path)) :u8vector))

(def (write-file-bytes (path : :string) (bytes : :u8vector)) => file-stat
  (:- (with-service-provider (provider file-system-service FileSystem) (FileSystem-write-file-bytes provider path bytes)) file-stat))

(def (list-folder (path : :string)) => :list
  (:- (with-service-provider (provider file-system-service FileSystem) (FileSystem-list-folder provider path)) :list))

(def (true-name (path : :string)) => :string
  (:- (with-service-provider (provider file-system-service FileSystem) (FileSystem-true-name provider path)) :string))

(def (watch-file (path : :string) (changed : :procedure)) => :void
  (:- (with-service-provider (provider file-system-service FileSystem) (FileSystem-watch-file provider path changed)) :void))

(def (unwatch-file (path : :string)) => :void
  (:- (with-service-provider (provider file-system-service FileSystem) (FileSystem-unwatch-file provider path)) :void))

(def (check-watched-files) => :void
  (:- (with-service-provider (provider file-system-service FileSystem) (FileSystem-check-watched-files provider)) :void))

;;; Visits

;; A text's file. FILE-NAME is the file as visited (Emacs's
;; buffer-file-name), TRUE-NAME it resolved. DISK and HASH (SHA-256 of
;; its bytes) are what was there at the last read or save, both #f for a
;; file not yet on disk; IDENTITY is DISK's. ENCODING is 'utf-8 for an
;; editable file, otherwise what kept it read-only: 'invalid-utf-8,
;; 'utf-16 or 'binary. LINE-ENDING is 'lf, 'crlf (every line; the text
;; holds plain newlines) or 'mixed (kept in the text as they are).
;; SAVED-REVISION is the text's character revision at the last read or
;; save, -1 when the file was deleted; SAVED-SIZE its size in characters
;; then, -1 when unknown, which tells most edited texts from saved ones
;; without hashing them. CONFLICT is the SHA-256 of the bytes another
;; program wrote to the file while the text had unsaved changes, else #f
;; (visit-conflict? says whether there is one). CHANGES changes
;; whenever the record does (tuna/lib/memo).
(defclass visit ((file-name      : :string)
                 (true-name      : :string)
                 (identity       :? :pair)
                 (disk           :? file-stat)
                 (hash           :? :u8vector)
                 (encoding       : :symbol)
                 (bom?           : :boolean)
                 (line-ending    : :symbol)
                 (final-newline? : :boolean)
                 (saved-revision : :fixnum)
                 (saved-size     : :fixnum)
                 (conflict       :? :u8vector)
                 (changes        : source))
  final: #t)

(def (visit-conflict? (v : visit)) => :boolean
  (and (visit-conflict v) #t))

(def (visit-editable? (v : visit)) => :boolean
  (eq? (visit-encoding v) 'utf-8))

(interface Files
  ;; The buffer showing the text that visits PATH, made if there is none.
  (find-file-noselect (path : :string)) => :t
  ;; T's visit, or #f.
  (text-visit (t : text)) => :t
  ;; Write B's text to its file; #f when it was refused, with a message.
  (save-buffer! (b : buffer)) => :boolean
  ;; Make B's text visit PATH instead, then save it there.
  (write-buffer! (b : buffer) (path : :string)) => :boolean
  ;; Read B's file again into B, without asking (revert-buffer).
  (revert-buffer! (b : buffer)) => :boolean
  ;; Whether T, which visits a file, differs from what the file held at
  ;; the last read or save.
  (text-modified? (t : text)) => :boolean
  ;; Plain data recover-file-buffer! makes B's file buffer from, or #f.
  (buffer-recovery-data (b : buffer)) => :t
  ;; The file buffer DATA describes, with CONTENT as its unsaved text.
  (recover-file-buffer! (data : :t) (content :? :string)) => :t)

(def files-service
  (new-service 'files is-Files? tier: 'live
               doc: "Texts that visit files: opening and saving."))

(def (find-file-noselect (path : :string)) => buffer
  (:- (with-service-provider (provider files-service Files) (Files-find-file-noselect provider path)) buffer))

;; Visit PATH in the selected view.
(def (find-file (path : :string)) => buffer
  (let (b (find-file-noselect path))
    (set-view-buffer (selected-view) b)
    b))

(def (text-visit (t : text)) => (Maybe visit)
  (:? (let (provider (service-provider files-service))
        (and provider (Files-text-visit (Files provider) t)))
      visit))

;; The visit of B's text, when B is one text node.
(def (buffer-visit (b : buffer)) => (Maybe visit)
  (let (root (buffer-root b))
    (and (text-node? root) (text-visit (text-node-content root)))))

;; The file B visits (Emacs `buffer-file-name`), or #f.
(def (buffer-file (b : buffer)) => (Maybe :string)
  (let (v (buffer-visit b))
    (and v (visit-file-name v))))

;; Whether B visits a file and its text differs from what the file held
;; at the last read or save (Emacs `buffer-modified-p` for file buffers,
;; except that undoing back to the saved text counts as unmodified).
(def (buffer-modified? (b : buffer)) => :boolean
  (let (v (buffer-visit b))
    (and v
         (begin
           (record-read! (visit-changes v))
           (:- (with-service-provider (provider files-service Files)
                 (Files-text-modified? provider (text-node-content (buffer-root b))))
               :boolean)))))

;; The buffers that visit files, oldest first.
(def (file-buffers) => :list
  (filter buffer-file (buffer-list)))

(def (save-buffer (b : buffer)) => :boolean
  (:- (with-service-provider (provider files-service Files) (Files-save-buffer! provider b)) :boolean))

;; Emacs's write-file: B visits PATH from now on and is saved there.
(def (write-file (b : buffer) (path : :string)) => :boolean
  (:- (with-service-provider (provider files-service Files) (Files-write-buffer! provider b path)) :boolean))

;; Make B show what is on disk again, discarding unsaved changes, as one
;; undoable change (Emacs's revert-buffer with NOCONFIRM): B's
;; revert-buffer-function if it has one, otherwise before-revert-hook,
;; reading its file, and after-revert-hook. #f when there was nothing to
;; read, with a message.
(def (revert-buffer (b : buffer)) => :boolean
  (:- (with-service-provider (provider files-service Files) (Files-revert-buffer! provider b)) :boolean))

;; Plain data (session data) from which recover-file-buffer makes B again:
;; its file, how the file's bytes became its text, and a hash of what was
;; on disk at the last read or save. #f when B visits no file.
(def (buffer-recovery-data (b : buffer)) => :t
  (with-service-provider (provider files-service Files) (Files-buffer-recovery-data provider b)))

;; The buffer visiting the file DATA (from buffer-recovery-data) names,
;; as after a restart (Emacs's recover-file). With CONTENT, the buffer
;; holds it as unsaved text: in conflict, with a message, when the file's
;; bytes are no longer those DATA recorded, so saving asks first; unsaved,
;; with a message, when the file is gone. Without CONTENT, the file is
;; read from disk. A buffer already visiting the file is kept as it is.
;; #f when DATA is not such data, or there is no CONTENT and no file.
(def (recover-file-buffer (data : :t) (content :? :string)) => (Maybe buffer)
  (:? (with-service-provider (provider files-service Files) (Files-recover-file-buffer! provider data content))
      buffer))

;;; Hooks. Each runs with the buffer. A callback that fails is reported in
;;; the echo area and on stderr (the kernel's run-hook) and removed.

(def auto-mode-hook
  (new-hook 'auto-mode doc: "Runs with a buffer that has just visited a file, before find-file-hook: where the plugin that chooses modes by file type sets one (Emacs's set-auto-mode)."))
(def find-file-hook
  (new-hook 'find-file doc: "Runs with a buffer once it visits a file."))
(def before-save-hook
  (new-hook 'before-save doc: "Runs with a buffer before its text is written to its file."))
(def after-save-hook
  (new-hook 'after-save doc: "Runs with a buffer after its text was written to its file."))
(def before-revert-hook
  (new-hook 'before-revert doc: "Runs with a buffer before its file is read into it again."))
(def after-revert-hook
  (new-hook 'after-revert doc: "Runs with a buffer after its file was read into it again."))

;;; Settings for changes on disk

;; Emacs leaves auto-revert off (global-auto-revert-mode); Tuna turns it
;; on, as other editors do, since a reload is one undoable change.
(defsetting auto-revert #t
  "Whether a file buffer with no unsaved changes is reloaded when another program changes its file.")
(defsetting auto-revert-use-notify #t
  "Whether file changes are noticed through the operating system's notifications (inotify) rather than by looking every auto-revert-interval seconds; read when watching starts.")
(defsetting auto-revert-interval 2
  "Seconds between looks at files that are polled, where notifications do not work.")
(defsetting revert-buffer-function #f
  "When a procedure, revert-buffer calls it with the buffer instead of reading the buffer's file (Emacs's revert-buffer-function).")

;; Emacs's write-contents-functions: a callback may write the buffer
;; itself instead of the file service. Callbacks run with the buffer and a
;; claim; context-add-save-takeover! adds one that runs only while the
;; claim is open.
(def save-takeover-hook
  (new-hook 'save-takeover doc: "Runs with a buffer about to be saved and a claim; a callback that saves it itself takes the claim."))

(defclass save-claim ((by :? :symbol)) final: #t)

;; Add SAVE, a procedure taking the buffer: it returns true when it saved
;; the buffer itself. The first that does wins; the others are not called.
(def (context-add-save-takeover! (ctx : context) (name : :symbol) (save : :procedure)) => :void
  (context-add-hook! ctx save-takeover-hook name
                     (lambda (b (claim : save-claim))
                       (unless (save-claim-by claim)
                         (when (save b)
                           (set! (save-claim-by claim) name))))))

;; Offer B to the save takeovers; the name of the one that saved it, or #f.
(def (run-save-takeovers (b : buffer)) => (Maybe :symbol)
  (let (claim (save-claim by: #f))
    (run-hook save-takeover-hook b claim)
    (save-claim-by claim)))

;;; Folders and file names

;; The folder a buffer's relative file names start from (Emacs
;; `default-directory`): a folder name ending in "/". #f means Tuna's
;; working folder.
(defsetting default-directory #f
  "The folder this buffer's file names are relative to; #f for Tuna's working folder.")

(def (buffer-default-directory (b : buffer)) => :string
  (let (folder (buffer-local-value default-directory b))
    (file-name-as-directory (if (string? folder) folder (current-directory)))))

;; The user's home folder, from HOME, without a trailing "/".
(def (home-directory) => :string
  (let (home (:- (getenv "HOME" "/") :string))
    (if (and (fx> (string-length home) 1) (string-suffix? "/" home))
      (substring home 0 (fx1- (string-length home)))
      home)))

(def (file-name-as-directory (name : :string)) => :string
  (if (string-suffix? "/" name) name (string-append name "/")))

;; NAME up to and including its last "/", or "" without one.
(def (file-name-directory (name : :string)) => :string
  (let (slash (string-rindex name #\/))
    (if slash (substring name 0 (fx1+ slash)) "")))

;; NAME after its last "/".
(def (file-name-nondirectory (name : :string)) => :string
  (let (slash (string-rindex name #\/))
    (if slash (substring name (fx1+ slash) (string-length name)) name)))

;; NAME as an absolute file name: "~" means the home folder, a relative
;; name starts from DIRECTORY, and "." and ".." are resolved without
;; looking at the disk. A name ending in "/" keeps it.
(def (expand-file-name (name : :string) (directory : :string)) => :string
  (let* ((full (cond
                ((or (string=? name "~") (string-prefix? "~/" name))
                 (string-append (home-directory) (substring name 1 (string-length name))))
                ((string-prefix? "/" name) name)
                (else (string-append (file-name-as-directory (expand-file-name directory "/")) name))))
         (folder? (or (string-suffix? "/" full) (string-suffix? "/." full) (string-suffix? "/.." full)))
         (parts (let lp ((rest (string-split full #\/)) (out []))
                  (match rest
                    ([] (reverse out))
                    ([part . more]
                     (cond
                      ((or (string-empty? part) (string=? part ".")) (lp more out))
                      ((string=? part "..") (lp more (if (pair? out) (cdr out) out)))
                      (else (lp more (cons part out)))))))))
    (if (null? parts)
      "/"
      (string-append "/" (string-join parts "/") (if folder? "/" "")))))

;; NAME with the home folder written "~".
(def (abbreviate-file-name (name : :string)) => :string
  (let (home (home-directory))
    (cond
     ((string=? home "/") name)
     ((string=? name home) "~")
     ((string-prefix? (string-append home "/") name)
      (string-append "~" (substring name (string-length home) (string-length name))))
     (else name))))
