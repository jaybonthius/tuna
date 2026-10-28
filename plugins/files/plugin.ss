#lang :tuna/prelude
;;; Files (live tier; ADR 5): the local disk as the file service, texts
;;; that visit files, and the commands to open and save them, with
;;; Emacs's keys: C-x C-f (find-file), C-x C-s (save-buffer), C-x s
;;; (save-some-buffers), C-x C-w (write-file).
;;;
;;; Visiting reads the file's bytes through the file service, decodes them
;;; (encoding.ss) and makes a buffer of one text node showing the text,
;;; whose folder is the buffer's default-directory. A file that is not
;;; UTF-8 opens read-only (buffer-read-only) with a note in the echo area,
;;; and saving it is refused. A file that does not exist yet gives an
;;; empty buffer; the first save creates it, but never a folder.
;;;
;;; Saving: before-save-hook, then the save takeovers, then (if none took
;;; it) the file service writes the bytes, then after-save-hook. The visit
;;; then records what is on disk, so later checks can tell Tuna's own
;;; writes from other programs'.
;;;
;;; Buffers visiting files with the same name are named after their
;;; folders too, as Emacs's uniquify does: "notes.txt<docs>",
;;; "notes.txt<work>"; with one left it is "notes.txt" again.
;;;
;;; The status line shows "*" for an unsaved file buffer and "read-only"
;;; for one that cannot be saved; killing an unsaved file buffer with
;;; C-x k asks first. A buffer is unsaved while its text differs from what
;;; was read or saved, so undoing back to it clears the "*"
;;; (text-modified?).
;;;
;;; Remembering, in session slots, both by true name: recent files
;;; (Emacs's recentf), most recent first, recorded when a file is visited
;;; or written to a new name, offered first in the picker and by
;;; recent-file, and dropped once they no longer exist; and remembered
;;; places (Emacs's save-place), each file's cursor position when its
;;; buffer is killed or saved, or the session saved, put back when the
;;; file is opened again.
;;;
;;; Changes on disk: the file service watches every visited file. When
;;; another program changes one, a buffer with no unsaved changes is
;;; reloaded (the auto-revert setting) by replacing only the lines that
;;; changed (line-diff.ss), as one undoable change, so cursors, marks and
;;; highlights elsewhere stay put and the buffer keeps its modes and
;;; settings; "Reloaded notes.txt". A buffer with unsaved changes is
;;; marked as in conflict ("notes.txt changed on disk", and in the status
;;; line); saving it asks whether to overwrite the file or reload it, with
;;; one key, o or r (as save-some-buffers' question takes one key). A
;;; file deleted or renamed away leaves its buffer unsaved. Saving looks
;;; at the file first in any case, and a browser tab that becomes visible
;;; or gains focus asks the file service to look at every file again
;;; (web/files.js). revert-buffer reloads on request.
;;;
;;; Recovery: buffer-recovery-data and recover-file-buffer! let the
;;; autosave plugin bring a file buffer back after a restart, with its
;;; unsaved text, compared with the file by hash: changed means conflict,
;;; gone means unsaved, both with a note.

(import (only-in :gerbil/runtime/hash HashTable)
        (only-in :std/crypto/digest sha256)
        (only-in :std/encoding/hex hex-encode hex-decode)
        :std/interface
        :tuna/kernel
        :tuna/lib/memo
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/renderer/contract
        :tuna/plugins/minibuffer/contract
        :tuna/plugins/completion/contract
        :tuna/plugins/session/contract
        :tuna/plugins/stylesheets/contract
        :tuna/plugins/web/contract
        :tuna/plugins/files/contract
        "local-disk"
        "encoding"
        "line-diff"
        "picker")
(export files
        file-buffer-names
        recent-files-limit
        remembered-places-limit)

(defsetting recent-files-limit 100 "How many recent files to remember (Emacs's recentf-max-saved-items).")
(defsetting remembered-places-limit 400 "How many files' cursor positions to remember (Emacs's save-place-limit).")

;;; Visits

(defclass files-state ((visits : HashTable)          ; text -> visit
                       (modified-checks : HashTable)  ; text -> (revision hash modified?), see text-modified?
                       (picker-keymap : entry-table)
                       (answer-keymap : entry-table)  ; one-key questions' keys
                       (answering : :list)            ; (prompt . answers) of those waiting, innermost first
                       (unwatched : :list)            ; visits made before the editor loop ran
                       (recent : :list)               ; true names, most recent first
                       (places : :list))              ; (true name . position), most recent first
  final: #t)

(def (text-of (b : buffer)) => text
  (text-node-content (buffer-root b)))

;; The buffer showing the text that visits TRUENAME or IDENTITY.
(def (visiting-buffer (truename : :string) (identity :? :pair)) => (Maybe buffer)
  (find (lambda ((b : buffer))
          (let (v (buffer-visit b))
            (and v (or (equal? (visit-true-name v) truename)
                       (and identity (equal? (visit-identity v) identity))))))
        (buffer-list)))

;; A visit of NAME, whose true name is TRUENAME, read as the other
;; arguments say; nothing recorded of the disk yet.
(def (new-visit (name : :string) (truename : :string) (encoding : :symbol) (bom? : :boolean)
                (line-ending : :symbol) (final-newline? : :boolean))
  => visit
  (visit file-name: name true-name: truename identity: #f disk: #f hash: #f
         encoding: encoding bom?: bom? line-ending: line-ending final-newline?: final-newline?
         saved-revision: -1 saved-size: -1 conflict: #f changes: (new-source)))

;; Record in V that DISK, whose bytes have the SHA-256 HASH, is what its
;; file now holds, and that the text's character REVISION, of SIZE
;; characters, matches it.
(def (record-disk! (v : visit) (disk :? file-stat) (hash :? :u8vector) (revision : :fixnum) (size : :fixnum))
  => :void
  (set! v.disk disk)
  (set! v.identity (and disk (file-stat-identity disk)))
  (set! v.hash hash)
  (set! v.saved-revision revision)
  (set! v.saved-size size)
  (set! v.conflict #f)
  (source-changed! (visit-changes v)))

;; Mark V as in conflict: another program changed its file to bytes with
;; the SHA-256 HASH while its text had unsaved changes.
(def (mark-conflict! (v : visit) (hash : :u8vector)) => :void
  (set! v.conflict hash)
  (source-changed! (visit-changes v)))

;; Whether T, which visits a file, differs from what the file held at the
;; last read or save. Its revision being the saved one says no and its
;; size differing says yes, so typing never hashes; otherwise (as after
;; undoing back to the saved text) the bytes saving would write are
;; hashed, once per revision.
(def (text-modified? (self : files-state) (t : text)) => :boolean
  (let (v (hash-get (files-state-visits self) t))
    (and v
         (let ((revision (text-chars-revision t))
               (hash (visit-hash v)))
           (cond
            ((fx= revision (visit-saved-revision v)) #f)
            ((or (not hash) (not (visit-editable? v)) (not (fx= (text-size t) (visit-saved-size v)))) #t)
            (else
             (let (checked (hash-get (files-state-modified-checks self) t))
               (if (and checked (fx= (car checked) revision) (eq? (cadr checked) hash))
                 (caddr checked)
                 (let (modified? (not (equal? hash (sha256 (encode-text (text-string t) (visit-bom? v)
                                                                        (visit-line-ending v))))))
                   (hash-put! (files-state-modified-checks self) t [revision hash modified?])
                   modified?)))))))))

;; The buffer whose text V visits.
(def (visit-buffer (v : visit)) => (Maybe buffer)
  (find (lambda ((b : buffer)) (eq? (buffer-visit b) v)) (buffer-list)))

(def (note-for (encoding : :symbol)) => :string
  (case encoding
    ((binary) "binary")
    ((utf-16) "UTF-16, which Tuna cannot edit yet")
    (else "not valid UTF-8")))

;;; Recent files and remembered places

(def (setting-limit (s : setting)) => :fixnum
  (let (limit (setting-value s))
    (unless (and (fixnum? limit) (fx>= limit 0))
      (error "A limit must be a non-negative integer:" (setting-name s) limit))
    limit))

(def (at-most (items : :list) (limit : :fixnum)) => :list
  (if (fx> (length items) limit) (take items limit) items))

(def (add-recent-file! (self : files-state) (truename : :string)) => :void
  (set! self.recent (at-most (cons truename (filter (lambda ((name : :string)) (not (equal? name truename)))
                                                    self.recent))
                             (setting-limit recent-files-limit))))

;; The recent files that still exist; the others are forgotten.
(def (existing-recent-files! (self : files-state)) => :list
  (set! self.recent (filter (lambda ((name : :string))
                              (let (stat (with-catch (lambda (e) #f) (lambda () (stat-file name))))
                                (and stat (eq? (file-stat-kind stat) 'file))))
                            self.recent))
  self.recent)

;; Saved recent files after those recorded since start.
(def (restore-recent-files! (self : files-state) (data : :t)) => :void
  (set! self.recent (at-most (append self.recent
                                     (filter (lambda (name) (and (string? name) (not (member name self.recent))))
                                             (if (list? data) data [])))
                             (setting-limit recent-files-limit))))

;; B's cursor position: the selected view's when it shows B, else the
;; first view's that does, else B's own.
(def (buffer-position (b : buffer)) => :fixnum
  (let (selected (selected-view))
    (if (eq? (view-showing selected) b)
      (view-point selected)
      (let (shown (find (lambda ((v : view)) (eq? (view-showing v) b)) (view-list)))
        (if shown (view-point shown) (buffer-point b))))))

;; PLACES with TRUENAME at POSITION, first. Position 1 is forgotten, as
;; Emacs's save-place does.
(def (with-place (places : :list) (truename : :string) (position : :fixnum)) => :list
  (let (others (filter (lambda ((place : :pair)) (not (equal? (car place) truename))) places))
    (at-most (if (fx> position 1) (cons (cons truename position) others) others)
             (setting-limit remembered-places-limit))))

(def (remember-place! (self : files-state) (b : buffer)) => :void
  (let (v (buffer-visit b))
    (when v
      (set! self.places (with-place self.places (visit-true-name v) (buffer-position b))))))

;; The remembered places, with every file buffer's position now.
(def (current-places (self : files-state)) => :list
  (foldl (lambda ((b : buffer) (places : :list))
           (with-place places (visit-true-name (:- (buffer-visit b) visit)) (buffer-position b)))
         self.places (file-buffers)))

;; Saved places after those remembered since start.
(def (restore-places! (self : files-state) (data : :t)) => :void
  (set! self.places (at-most (append self.places
                                     (filter (lambda (place)
                                               (and (pair? place) (string? (car place)) (fixnum? (cdr place))
                                                    (not (assoc (car place) self.places))))
                                             (if (list? data) data [])))
                             (setting-limit remembered-places-limit))))

;;; Buffer names

;; ENTRIES are (key . file-name) pairs; each key gets its file's name, and
;; files that share a name get the shortest run of their folders' names
;; that tells them apart: (key . "notes.txt<docs>").
(def (file-buffer-names (entries : :list)) => :list
  (let (folders-of (lambda ((name : :string))
                     (reverse (filter (lambda ((part : :string)) (not (string-empty? part)))
                                      (string-split (file-name-directory name) #\/)))))
    (map (lambda ((entry : :pair))
           (let* ((name (cdr entry))
                  (base (file-name-nondirectory name))
                  (same (filter (lambda ((other : :pair))
                                  (and (not (eq? other entry))
                                       (equal? (file-name-nondirectory (cdr other)) base)))
                                entries)))
             (if (null? same)
               (cons (car entry) base)
               (let* ((mine (folders-of name))
                      (theirs (map (lambda ((other : :pair)) (folders-of (cdr other))) same))
                      (suffix (lambda ((folders : :list) (n : :fixnum))
                                (string-join (reverse (take folders (fxmin n (length folders)))) "/"))))
                 (let lp ((n 1))
                   (let (mine-n (suffix mine n))
                     (if (or (fx>= n (length mine))
                             (not (member mine-n (map (lambda ((folders : :list)) (suffix folders n)) theirs))))
                       (cons (car entry) (string-append base "<" mine-n ">"))
                       (lp (fx1+ n)))))))))
         entries)))

;; NAME, or NAME<2>, NAME<3>... when another buffer than the KEEP has it.
(def (free-name (name : :string) (taken : :list)) => :string
  (if (not (member name taken))
    name
    (let lp ((n 2))
      (let (candidate (string-append name "<" (number->string n) ">"))
        (if (member candidate taken) (lp (fx1+ n)) candidate)))))

;; Name every file buffer but GONE after its file, as file-buffer-names
;; says; NEW, if given, is a buffer not yet added, visiting NEW-FILE.
;; Returns NEW's name.
(def (rename-file-buffers! (gone :? buffer) (new :? buffer) (new-file :? :string)) => (Maybe :string)
  (let* ((visiting (filter (lambda ((b : buffer)) (not (eq? b gone))) (file-buffers)))
         (entries (append (map (lambda ((b : buffer)) (cons b (buffer-file b))) visiting)
                          (if new [(cons new new-file)] [])))
         (names (file-buffer-names entries))
         (others (filter-map (lambda ((b : buffer))
                               (and (not (memq b visiting)) (not (eq? b gone)) (buffer-name b)))
                             (buffer-list)))
         (wanted (let lp ((rest names) (taken others) (out []))
                   (match rest
                     ([] (reverse out))
                     ([[key . name] . more]
                      (let (free (free-name name taken))
                        (lp more (cons free taken) (cons (cons key free) out)))))))
         (moving (filter (lambda ((pair : :pair))
                           (and (not (eq? (car pair) new))
                                (not (equal? (buffer-name (car pair)) (cdr pair)))))
                         wanted)))
    ;; Through names no buffer has, so two buffers can swap names.
    (for-each (lambda ((pair : :pair))
                (rename-buffer! (car pair) (string-append " *files-renaming-" (number->string (next-id!)) "*")))
              moving)
    (for-each (lambda ((pair : :pair)) (rename-buffer! (car pair) (cdr pair))) moving)
    (let (mine (assq new wanted))
      (and mine (cdr mine)))))

;;; Visiting

(def (visit-file! (self : files-state) (path : :string)) => buffer
  (let* ((name (expand-file-name path (buffer-default-directory (current-buffer))))
         (stat (stat-file name)))
    (when (and stat (eq? (file-stat-kind stat) 'folder))
      (error "This is a folder, not a file:" (abbreviate-file-name name)))
    (when (and stat (not (eq? (file-stat-kind stat) 'file)))
      (error "This is not a regular file:" (abbreviate-file-name name)))
    (let (truename (true-name name))
      (add-recent-file! self truename)
      (or (visiting-buffer truename (and stat (file-stat-identity stat)))
          (new-file-buffer! self name truename stat)))))

(def (new-file-buffer! (self : files-state) (name : :string) (truename : :string) (stat :? file-stat)) => buffer
  (let* ((bytes (and stat (read-file-bytes name)))
         (d (if bytes (decode-file-bytes bytes) (make-decoded "" 'utf-8 #f 'lf #f)))
         (t (new-text (decoded-text d)))
         (v (new-visit name truename (decoded-encoding d) (decoded-bom? d)
                       (decoded-line-ending d) (decoded-final-newline? d)))
         (place (and stat (assoc truename (files-state-places self)))))
    (record-disk! v stat (and bytes (sha256 bytes)) (text-chars-revision t) (text-size t))
    (let (b (add-file-buffer! self t v (if place (cdr place) 1)))
      (cond
       ((not stat) (message "(New file)"))
       ((not (visit-editable? v))
        (message (string-append (abbreviate-file-name name) " is " (note-for (visit-encoding v))
                                "; opened read-only"))))
      b)))

;; Add a buffer showing T, which visits V, at POINT (clamped): named after
;; its file, in its folder, watched, and read-only when the file cannot be
;; edited; then auto-mode-hook and find-file-hook run.
(def (add-file-buffer! (self : files-state) (t : text) (v : visit) (point : :fixnum)) => buffer
  (let (b (new-buffer (string-append " *files-new-" (number->string (next-id!)) "*") (new-text-node t)))
    (hash-put! (files-state-visits self) t v)
    ;; Watching runs a source, which needs the editor loop; buffers made
    ;; before it runs (restored at start) are watched once the first task
    ;; runs, and the watcher's first look reports what changed meanwhile.
    (if (editor-loop-running?)
      (watch-visit! v)
      (set! (files-state-unwatched self) (cons v (files-state-unwatched self))))
    (set-buffer-setting! b default-directory (file-name-directory (visit-file-name v)))
    (set-buffer-point! b (fxmax 1 (fxmin point (fx1+ (text-size t)))))
    (unless (visit-editable? v)
      (set-buffer-setting! b buffer-read-only #t))
    (rename-buffer! b (rename-file-buffers! #f b (visit-file-name v)))
    (add-buffer! b)
    (run-hook auto-mode-hook b)
    (run-hook find-file-hook b)
    b))

;;; Recovery after a restart

;; B's visit as plain data for recover-file!: (FILE-NAME TRUE-NAME
;; ENCODING BOM? LINE-ENDING FINAL-NEWLINE? HASH), HASH in hexadecimal or #f.
(def (buffer-recovery-data (b : buffer)) => :t
  (let (v (buffer-visit b))
    (and v
         [(visit-file-name v) (visit-true-name v) (visit-encoding v) (visit-bom? v) (visit-line-ending v)
          (visit-final-newline? v) (let (hash (visit-hash v)) (and hash (hex-encode hash)))])))

;; The buffer visiting the file DATA (from buffer-recovery-data) names:
;; one already open, or one holding CONTENT unsaved, or, without CONTENT,
;; the file read again.
(def (recover-file! (self : files-state) (data : :t) (content :? :string)) => (Maybe buffer)
  (match data
    ([(? string? name) (? string? truename) (? symbol? encoding) (? boolean? bom?) (? symbol? line-ending)
      (? boolean? final-newline?) hash-hex]
     (and (string-prefix? "/" name)
          (memq line-ending '(lf crlf mixed))
          (or (not hash-hex) (string? hash-hex))
          (let* ((stat (stat-file name))
                 (file (and stat (eq? (file-stat-kind stat) 'file) stat)))
            (cond
             ((visiting-buffer truename (and file (file-stat-identity file))))
             ((not content) (and file (new-file-buffer! self name (true-name name) file)))
             (else
              (recovered-file-buffer! self (new-visit name (if file (true-name name) truename)
                                                      encoding bom? line-ending final-newline?)
                                      (and hash-hex (hex-decode hash-hex)) file content))))))
    (else #f)))

;; A buffer holding CONTENT, unsaved text kept while V's file held bytes
;; with the SHA-256 RECORDED (#f: none); FILE is what is there now.
;; Changed bytes put it in conflict and missing ones leave it unsaved,
;; both with a note.
(def (recovered-file-buffer! (self : files-state) (v : visit) (recorded :? :u8vector) (file :? file-stat)
                             (content : :string))
  => buffer
  (let* ((t (new-text content))
         (bytes (and file (read-file-bytes (visit-file-name v))))
         (hash (and bytes (sha256 bytes)))
         (note (cond
                ((not bytes)
                 (record-disk! v #f #f -1 -1)
                 (and recorded "was deleted on disk while Tuna was not running"))
                ((and (visit-editable? v)
                      (equal? hash (sha256 (encode-text content (visit-bom? v) (visit-line-ending v)))))
                 (record-disk! v file hash (text-chars-revision t) (text-size t))
                 #f)
                ((equal? hash recorded)
                 (record-disk! v file hash -1 (string-length (decoded-text (decode-file-bytes bytes))))
                 #f)
                (else
                 (record-disk! v file recorded -1 -1)
                 (mark-conflict! v hash)
                 "changed on disk while Tuna was not running"))))
    (let (b (add-file-buffer! self t v 1))
      (when note
        (message (string-append (buffer-name b) " " note)))
      b)))

;;; Changes on disk

;; Have the file service tell V when its file may have changed.
(def (watch-visit! (v : visit)) => :void
  (watch-file (visit-true-name v) (lambda (hash) (disk-changed! v hash))))

;; Whether stats A and B, either #f for nothing there, are the same file
;; as last seen.
(def (same-disk? (a :? file-stat) (b :? file-stat)) => :boolean
  (if (and a b)
    (and (eq? (file-stat-kind a) (file-stat-kind b))
         (= (file-stat-size a) (file-stat-size b))
         (= (file-stat-modified a) (file-stat-modified b))
         (equal? (file-stat-identity a) (file-stat-identity b)))
    (not (or a b))))

;; Whether HASH is that of the bytes saving B, which visits V, would write.
(def (same-as-text? (b : buffer) (v : visit) (hash : :u8vector)) => :boolean
  (and (visit-editable? v)
       (equal? hash (sha256 (encode-text (text-string (text-of b)) (visit-bom? v) (visit-line-ending v))))))

;; On the editor thread, after the file service saw V's file change:
;; REPORTED is the SHA-256 of its bytes then, or #f. The stat alone cannot
;; tell, since a file written twice within the file system's clock tick
;; keeps its size and modification time.
(def (disk-changed! (v : visit) (reported :? :u8vector)) => :void
  (let (b (visit-buffer v))
    (when b
      (let* ((name (visit-file-name v))
             (stat (stat-file name)))
        (cond
         ((not stat)
          (when (visit-disk v)
            (record-disk! v #f #f -1 -1)
            (message (string-append (buffer-name b) " was deleted on disk"))))
         ((not (eq? (file-stat-kind stat) 'file)) (void))
         ((and reported (equal? reported (visit-hash v)))
          (unless (same-disk? stat (visit-disk v))
            (record-disk! v stat reported (visit-saved-revision v) (visit-saved-size v))))
         (else
          (let* ((bytes (read-file-bytes name))
                 (hash (sha256 bytes)))
            (cond
             ((equal? hash (visit-hash v))
              ;; Touched, or changed back: only its attributes are new.
              (record-disk! v stat hash (visit-saved-revision v) (visit-saved-size v)))
             ((same-as-text? b v hash)
              (record-disk! v stat hash (text-chars-revision (text-of b)) (text-size (text-of b))))
             ((and (not (buffer-modified? b)) (buffer-local-value auto-revert b))
              (let (override (buffer-local-value revert-buffer-function b))
                (if (procedure? override)
                  (override b)
                  (reload! b v stat bytes)))
              (message (string-append "Reloaded " (buffer-name b))))
             ;; Already noticed (as when the first look after a restart
             ;; reports what recovering found).
             ((equal? hash (visit-conflict v)) (void))
             (else
              (mark-conflict! v hash)
              (message (string-append (buffer-name b) " changed on disk")))))))))))

;; Make B, which visits V, hold BYTES, read from its file with STAT: the
;; lines that changed are replaced as one undoable change, and B keeps its
;; modes and settings, and is unmodified afterwards.
(def (reload! (b : buffer) (v : visit) (stat : file-stat) (bytes : :u8vector)) => :void
  (run-hook before-revert-hook b)
  (let* ((t (text-of b))
         (d (decode-file-bytes bytes))
         (was-editable? (visit-editable? v)))
    (undo-boundary! t)
    (for-each (lambda ((e : text-edit))
                (text-replace! t (text-edit-start e) (text-edit-end e) (text-edit-replacement e)))
              (text-edits (text-string t) (decoded-text d)))
    (undo-boundary! t)
    (set! v.encoding (decoded-encoding d))
    (set! v.bom? (decoded-bom? d))
    (set! v.line-ending (decoded-line-ending d))
    (set! v.final-newline? (decoded-final-newline? d))
    (record-disk! v stat (sha256 bytes) (text-chars-revision t) (text-size t))
    (cond
     ((not (visit-editable? v)) (set-buffer-setting! b buffer-read-only #t))
     ((not was-editable?) (set-buffer-setting! b buffer-read-only #f))))
  (run-hook after-revert-hook b))

;; Emacs's revert-buffer without asking: B's revert-buffer-function, or
;; its file read again.
(def (revert-buffer! (b : buffer)) => :boolean
  (let ((override (buffer-local-value revert-buffer-function b))
        (v (buffer-visit b)))
    (cond
     ((procedure? override) (override b) #t)
     ((not v) (message (string-append (buffer-name b) " is not visiting a file")) #f)
     (else
      (let (stat (stat-file (visit-file-name v)))
        (if (and stat (eq? (file-stat-kind stat) 'file))
          (begin
            (reload! b v stat (read-file-bytes (visit-file-name v)))
            #t)
          (begin
            (message (string-append (abbreviate-file-name (visit-file-name v)) " is not on disk"))
            #f)))))))

;; The answers to the question about a file changed on disk, by key.
(def conflict-answers
  '(("o" . overwrite) ("r" . reload)))

;; Ask what to do about B's file, changed on disk by another program:
;; 'overwrite or 'reload. C-g quits.
(def (ask-about-conflict (self : files-state) (b : buffer)) => :symbol
  (ask-one-key self (string-append (buffer-name b) " changed on disk; save anyway? "
                                   "[o]verwrite with yours, [r]eload theirs, C-g cancels ")
               conflict-answers))

;; Before saving B, which visits V: whether to go on. A file another
;; program changed asks first; answering reload reloads it instead.
(def (disk-allows-save? (self : files-state) (b : buffer) (v : visit)) => :boolean
  (let* ((name (visit-file-name v))
         (stat (stat-file name)))
    (if (or (not stat) (not (eq? (file-stat-kind stat) 'file))
            (and (not (visit-conflict? v)) (same-disk? stat (visit-disk v))))
      #t
      (let* ((bytes (read-file-bytes name))
             (hash (sha256 bytes)))
        (cond
         ((equal? hash (visit-hash v))
          (record-disk! v stat hash (visit-saved-revision v) (visit-saved-size v))
          #t)
         ((same-as-text? b v hash) #t)
         ((eq? (ask-about-conflict self b) 'overwrite) #t)
         (else
          (reload! b v stat bytes)
          (message (string-append "Reloaded " (buffer-name b)))
          #f))))))

;;; Saving

;; Report a failed save of B in the echo area and on stderr.
(def (report-save-failure (b : buffer) (e : :t)) => :void
  (let (text (string-append "Could not save " (buffer-name b) ": " (exception-summary e)))
    (display text (current-error-port))
    (newline (current-error-port))
    (message text)))

;; Write B, which visits V, to its file whether or not it changed.
(def (save! (b : buffer) (v : visit)) => :boolean
  (run-hook before-save-hook b)
  (let* ((t (text-of b))
         (revision (text-chars-revision t))
         (size (text-size t))
         (new? (not (visit-disk v)))
         (taker (run-save-takeovers b)))
    (and (with-catch
          (lambda (e) (report-save-failure b e) #f)
          (lambda ()
            (if taker
              (let (disk (stat-file (visit-file-name v)))
                (record-disk! v disk (and disk (sha256 (read-file-bytes (visit-file-name v)))) revision size))
              (let* ((text (text-string t))
                     (bytes (encode-text text (visit-bom? v) (visit-line-ending v)))
                     (disk (write-file-bytes (visit-file-name v) bytes)))
                (set! v.final-newline? (string-suffix? "\n" text))
                (when new?
                  (let (truename (true-name (visit-file-name v)))
                    (unless (equal? truename (visit-true-name v))
                      (unwatch-file (visit-true-name v))
                      (set! v.true-name truename)
                      (watch-visit! v))))
                (record-disk! v disk (sha256 bytes) revision size)))
            #t))
         (begin
           (message (string-append "Wrote " (abbreviate-file-name (visit-file-name v))))
           (run-hook after-save-hook b)
           #t))))

(def (save-buffer! (self : files-state) (b : buffer)) => :boolean
  (let (v (buffer-visit b))
    (cond
     ((not v) (message (string-append (buffer-name b) " is not visiting a file")) #f)
     ((not (visit-editable? v))
      (message (string-append (buffer-name b) " is read-only (" (note-for (visit-encoding v)) "); not saved"))
      #f)
     ((and (not (buffer-modified? b)) (visit-disk v))
      (message "(No changes need to be saved)")
      #t)
     ((not (disk-allows-save? self b v)) #f)
     (else (save! b v)))))

;; B visits PATH from now on (Emacs set-visited-file-name), then is saved.
(def (write-buffer! (self : files-state) (b : buffer) (path : :string)) => :boolean
  (unless (text-node? (buffer-root b))
    (error "Only a buffer of one text can visit a file:" (buffer-name b)))
  (let* ((name (let (full (expand-file-name path (buffer-default-directory b)))
                 (let (stat (stat-file full))
                   (if (or (string-suffix? "/" full) (and stat (eq? (file-stat-kind stat) 'folder)))
                     (string-append (file-name-as-directory full) (buffer-name b))
                     full))))
         (truename (true-name name))
         (other (visiting-buffer truename (let (stat (stat-file name)) (and stat (file-stat-identity stat)))))
         (old (buffer-visit b)))
    (cond
     ((and other (not (eq? other b)))
      (message (string-append (abbreviate-file-name name) " is open in " (buffer-name other)))
      #f)
     ((and old (not (visit-editable? old)))
      (message (string-append (buffer-name b) " is read-only (" (note-for (visit-encoding old)) "); not written"))
      #f)
     (else
      (using (v (or old
                    (let (v (new-visit name truename 'utf-8 #f 'lf #f))
                      (hash-put! (files-state-visits self) (text-of b) v)
                      v))
                : visit)
        (when old
          (unwatch-file (visit-true-name v)))
        (set! v.file-name name)
        (set! v.true-name truename)
        (record-disk! v #f #f -1 -1)
        (watch-visit! v)
        (set-buffer-setting! b default-directory (file-name-directory name))
        (rename-file-buffers! #f #f #f)
        (and (save! b v)
             (begin (add-recent-file! self (visit-true-name v)) #t)))))))

(implement Files files-state
  (find-file-noselect (lambda (self path) (visit-file! self path)))
  (text-visit (lambda (self t) (hash-get (files-state-visits self) t)))
  (save-buffer! (lambda (self b) (save-buffer! self b)))
  (write-buffer! (lambda (self b path) (write-buffer! self b path)))
  (revert-buffer! (lambda (self b) (revert-buffer! b)))
  (text-modified? (lambda (self t) (text-modified? self t)))
  (buffer-recovery-data (lambda (self b) (buffer-recovery-data b)))
  (recover-file-buffer! (lambda (self data content) (recover-file! self data content))))

;;; Questions

;; Ask QUESTION until the answer is "yes" or "no" (Emacs yes-or-no-p).
(def (yes-or-no? (question : :string)) => :boolean
  (let lp ()
    (let (answer (read-string (string-append question "(yes or no) ")))
      (cond
       ((equal? answer "yes") #t)
       ((equal? answer "no") #f)
       (else (message "Please answer yes or no.") (lp))))))

;; Ask QUESTION, answered by one key (Emacs's read-multiple-choice):
;; ANSWERS maps each key ("y", "SPC") to the symbol returned; any other
;; key is refused with a note, and C-g quits.
(def (ask-one-key (self : files-state) (question : :string) (answers : :list)) => :symbol
  (let (asked #f)
    (unwind-protect
      (:- (read-from-minibuffer
           question
           setup: (lambda ((p : Prompt))
                    (set! asked p)
                    (set! (files-state-answering self) (cons (cons p answers) (files-state-answering self)))
                    (set-node-keymap! (prompt-answer-node p) (files-state-answer-keymap self))))
          :symbol)
      (set! (files-state-answering self)
        (filter (lambda ((waiting : :pair)) (not (eq? (car waiting) asked))) (files-state-answering self))))))

;; The key that answers a one-key question: the last key typed.
(def (answer-key) => :string
  (let (event (last-command-event))
    (if (key-event? event)
      (let (key (:- (key-event-key event) :string))
        (cond ((equal? key " ") "SPC")
              ((equal? key "Backspace") "DEL")
              ((equal? key "Enter") "RET")
              (else key)))
      "")))

;; Answer the innermost one-key question with the key typed.
(def (answer-one-key! (self : files-state)) => :void
  (match (files-state-answering self)
    ([[p . answers] . _]
     (let* ((key (answer-key))
            (answer (assoc key answers)))
       (if answer
         (prompt-exit! p (cdr answer) history-text: key)
         (message (string-append "Please answer " (string-join (map car answers) ", "))))))
    (else (void))))

;; The answers to save-some-buffers' question, by the key typed.
(def save-answers
  '(("y" . save) ("SPC" . save) ("n" . skip) ("DEL" . skip)
    ("!" . save-all) ("." . save-and-stop) ("q" . stop) ("RET" . stop)))

;; Ask whether to save B; one of save-answers' answers.
(def (ask-save (self : files-state) (b : buffer)) => :symbol
  (ask-one-key self (string-append "Save file " (abbreviate-file-name (buffer-file b)) "? (y, n, !, ., q) ")
               save-answers))

;; Ask with QUESTION for a file for B to visit from now on, and save B
;; there; overwriting another file asks first.
(def (write-file-asking! (self : files-state) (b : buffer) (question : :string)) => :void
  (let* ((name (read-file-to-visit self question #f))
         (stat (stat-file name)))
    (when (or (not stat) (eq? (file-stat-kind stat) 'folder)
              (equal? (buffer-file b) name)
              (yes-or-no? (string-append "File " (abbreviate-file-name name) " exists; overwrite? ")))
      (write-file b name))))

;; Offer each unsaved file buffer for saving, as Emacs's save-some-buffers.
(def (save-some-buffers! (self : files-state)) => :void
  (let lp ((rest (filter buffer-modified? (file-buffers))) (all? #f) (saved 0))
    (match rest
      ([] (message (if (fx= saved 0) "(No files need saving)"
                       (string-append "Saved " (number->string saved) " file" (if (fx= saved 1) "" "s")))))
      ([b . more]
       (let (answer (if all? 'save (ask-save self b)))
         (case answer
           ((save) (lp more all? (if (save-buffer! self b) (fx1+ saved) saved)))
           ((save-all) (lp more #t (if (save-buffer! self b) (fx1+ saved) saved)))
           ((save-and-stop) (lp [] all? (if (save-buffer! self b) (fx1+ saved) saved)))
           ((skip) (lp more all? saved))
           (else (lp [] all? saved))))))))

;; The kill query: an unsaved file buffer asks first.
(def (kill-unsaved? (b : buffer)) => :boolean
  (or (not (buffer-modified? b))
      (yes-or-no? (string-append "Buffer " (buffer-name b) " modified; kill anyway? "))))

;;; Commands

;; The file name to visit, read with the picker from the current buffer's
;; folder, offering recent files first when RECENT?; RET on a folder opens
;; the picker there.
(def (read-file-to-visit (self : files-state) (question : :string) (recent? : :boolean)) => :string
  (let lp ((initial (abbreviate-file-name (buffer-default-directory (current-buffer)))))
    (let* ((from (buffer-default-directory (current-buffer)))
           (sources (if recent?
                      [(recent-file-table (existing-recent-files! self) "Recent files" initial) (file-completion-table from)]
                      [(file-completion-table from)]))
           (answer (completing-read question sources
                                    require-match: #f initial: initial history: 'file
                                    setup: (lambda ((p : Prompt))
                                             (wrap-picker-answer! p (files-state-picker-keymap self)))))
           (name (expand-file-name (:- answer :string) from))
           (stat (stat-file name)))
      (if (and stat (eq? (file-stat-kind stat) 'folder) (not (equal? (file-name-as-directory name) (expand-file-name initial from))))
        (lp (abbreviate-file-name (file-name-as-directory name)))
        name))))

(defplugin (files ctx)
  "Opens and saves files: C-x C-f, C-x C-s, C-x s, C-x C-w, recent-file, revert-buffer; reloads files other programs change; remembers recent files and cursor places; the local disk as the file service."
  provides: [file-system-service files-service]
  requires: [commands-service input-service buffers-service layout-service settings-service
             minibuffer-service completion-service session-service]
  optional: [renderer-service completion-ui-service page-service]
  (def disk (FileSystem (new-local-disk ctx (lambda () (path-expand "file-backups" (state-directory))))))
  (add-stylesheet 'rules "rules.css")
  (context-provide! ctx file-system-service disk)
  (when (service-provider page-service)
    ;; A tab that becomes visible or gains focus posts here: look at every
    ;; watched file again. On the request's thread, so through DISK itself.
    (add-script "web/files.js")
    (context-add-page-address! ctx "check" (lambda (c bytes) (FileSystem-check-watched-files disk))))
  (using (self (files-state visits: (make-hash-table-eq weak-keys: #t)
                            modified-checks: (make-hash-table-eq weak-keys: #t)
                            picker-keymap: (new-keymap) answer-keymap: (new-keymap) answering: [] unwatched: []
                            recent: [] places: [])
               : files-state)
    (context-provide! ctx files-service (Files self))
    (context-define-node-kind! ctx 'file-picker-input items: 'children
                               doc: "The file picker's answer, with the picker's keys.")
    (context-define-node-renderer! ctx 'file-picker-input
                                   (lambda (n children) `(span (@ (class "file-picker-input")) ,@children)))
    (context-define-annotator! ctx 'file file-annotations)
    (context-add-status-line-part! ctx 'files
      (lambda ((b : buffer))
        (let (v (buffer-visit b))
          (cond
           ((not v) #f)
           ((not (visit-editable? v)) "read-only")
           ((visit-conflict? v) "* changed on disk")
           ((buffer-modified? b) "*")
           (else #f)))))
    (context-add-kill-buffer-query! ctx 'files kill-unsaved?)
    (context-add-hook! ctx task-started-hook 'files
      (lambda (id name)
        (let (waiting (files-state-unwatched self))
          (when (pair? waiting)
            (set! (files-state-unwatched self) [])
            (for-each (lambda ((v : visit)) (when (visit-buffer v) (watch-visit! v))) waiting)))))
    (context-add-session-slot! ctx 'recent-files version: 1
      save: (lambda () (files-state-recent self))
      restore: (lambda (data) (restore-recent-files! self data)))
    (context-add-session-slot! ctx 'remembered-places version: 1
      save: (lambda () (current-places self))
      restore: (lambda (data) (restore-places! self data)))
    (context-add-hook! ctx after-save-hook 'remembered-places
      (lambda ((b : buffer)) (remember-place! self b)))
    (context-add-hook! ctx kill-buffer-hook 'files
      (lambda ((b : buffer))
        (when (buffer-visit b)
          (unwatch-file (visit-true-name (:- (buffer-visit b) visit)))
          (remember-place! self b)
          (rename-file-buffers! b #f #f)
          (hash-remove! (files-state-visits self) (text-of b)))))
    (defcommand (find-file) "Visit a file, chosen with the file picker, in the selected view; a new name makes a new file on first save."
      (find-file (read-file-to-visit self "Find file: " #t)))
    (defcommand (recent-file) "Visit a recently visited file, chosen from the most recent first."
      (let (files (existing-recent-files! self))
        (if (null? files)
          (message "No recent files")
          (find-file (:- (completing-read "Find recent file: " [(recent-file-table files #f #f)] history: 'file)
                         :string)))))
    (defcommand (save-buffer) "Save the current buffer to its file, if it changed; a changed buffer with no file asks for one, which it visits from then on."
      (let (b (current-buffer))
        (cond
         ((buffer-visit b) (save-buffer b))
         ;; Emacs's basic-save-buffer: a buffer with no file asks for one,
         ;; if it changed. Tuna has no modified flag for such buffers, so
         ;; any change since the text was made counts.
         ((and (text-node? (buffer-root b)) (fx> (text-chars-revision (text-of b)) 0))
          (write-file-asking! self b "File to save in: "))
         (else (message "(No changes need to be saved)")))))
    (defcommand (revert-buffer) "Read the current buffer's file again, as one undoable change, asking first when the buffer has unsaved changes."
      (let (b (current-buffer))
        (when (or (not (buffer-modified? b))
                  (yes-or-no? (string-append "Discard your changes to " (buffer-name b) " and reload it from disk? ")))
          (when (and (revert-buffer b) (buffer-visit b))
            (message (string-append "Reloaded " (buffer-name b)))))))
    (defcommand (save-some-buffers) "Offer each unsaved file buffer for saving: y or SPC saves, n or DEL skips, ! saves the rest, . saves this one and stops, q or RET stops."
      (save-some-buffers! self))
    (defcommand (write-file) "Save the current buffer to another file, which it visits from then on."
      (write-file-asking! self (current-buffer) "Write file: "))
    (context-define-command! ctx 'file-picker-slash picker-slash!
      doc: "In the file picker: insert \"/\"; \"~/\" there jumps home."
      visible?: (lambda (c origin) #f))
    (context-define-command! ctx 'files-answer-key (lambda () (answer-one-key! self))
      doc: "Answer the question asked (save-some-buffers', or about a file changed on disk) with the key typed."
      visible?: (lambda (c origin) #f))
    (keymap-set-in ctx (files-state-picker-keymap self) "/" 'file-picker-slash)
    (for-each (lambda ((key : :string))
                (keymap-set-in ctx (files-state-answer-keymap self) key 'files-answer-key))
              [printing-char-key "SPC" "DEL" "RET"])
    (keymap-set "C-x C-f" 'find-file)
    (keymap-set "C-x C-s" 'save-buffer)
    (keymap-set "C-x s" 'save-some-buffers)
    (keymap-set "C-x C-w" 'write-file)))
