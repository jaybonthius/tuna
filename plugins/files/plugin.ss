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
;;; C-x k asks first.

(import (only-in :gerbil/runtime/hash HashTable)
        (only-in :std/crypto/digest sha256)
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
        :tuna/plugins/files/contract
        "local-disk"
        "encoding"
        "picker")
(export files
        file-buffer-names)

;;; Visits

(defclass files-state ((visits : HashTable)          ; text -> visit
                       (picker-keymap : entry-table)
                       (answer-keymap : entry-table)  ; save-some-buffers' one-key answers
                       (answering : :list))           ; its prompts waiting, innermost first
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

;; Record in V that DISK, holding BYTES, is what its file now holds, and
;; that the text's character REVISION matches it.
(def (record-disk! (v : visit) (disk :? file-stat) (bytes :? :u8vector) (revision : :fixnum)) => :void
  (set! v.disk disk)
  (set! v.identity (and disk (file-stat-identity disk)))
  (set! v.hash (and bytes (sha256 bytes)))
  (set! v.saved-revision revision)
  (source-changed! (visit-changes v)))

(def (note-for (encoding : :symbol)) => :string
  (case encoding
    ((binary) "binary")
    ((utf-16) "UTF-16, which Tuna cannot edit yet")
    (else "not valid UTF-8")))

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
      (or (visiting-buffer truename (and stat (file-stat-identity stat)))
          (new-file-buffer! self name truename stat)))))

(def (new-file-buffer! (self : files-state) (name : :string) (truename : :string) (stat :? file-stat)) => buffer
  (let* ((bytes (and stat (read-file-bytes name)))
         (d (if bytes (decode-file-bytes bytes) (make-decoded "" 'utf-8 #f 'lf #f)))
         (t (new-text (decoded-text d)))
         (b (new-buffer (string-append " *files-new-" (number->string (next-id!)) "*") (new-text-node t)))
         (v (visit file-name: name true-name: truename identity: #f disk: #f hash: #f
                   encoding: (decoded-encoding d) bom?: (decoded-bom? d)
                   line-ending: (decoded-line-ending d) final-newline?: (decoded-final-newline? d)
                   saved-revision: 0 changes: (new-source))))
    (record-disk! v stat bytes (text-chars-revision t))
    (hash-put! (files-state-visits self) t v)
    (set-buffer-setting! b default-directory (file-name-directory name))
    (unless (visit-editable? v)
      (set-buffer-setting! b buffer-read-only #t))
    (rename-buffer! b (rename-file-buffers! #f b name))
    (add-buffer! b)
    (run-hook auto-mode-hook b)
    (run-hook find-file-hook b)
    (cond
     ((not stat) (message "(New file)"))
     ((not (visit-editable? v))
      (message (string-append (abbreviate-file-name name) " is " (note-for (visit-encoding v))
                              "; opened read-only"))))
    b))

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
         (new? (not (visit-disk v)))
         (taker (run-save-takeovers b)))
    (and (with-catch
          (lambda (e) (report-save-failure b e) #f)
          (lambda ()
            (if taker
              (let (disk (stat-file (visit-file-name v)))
                (record-disk! v disk (and disk (read-file-bytes (visit-file-name v))) revision))
              (let* ((text (text-string t))
                     (bytes (encode-text text (visit-bom? v) (visit-line-ending v)))
                     (disk (write-file-bytes (visit-file-name v) bytes)))
                (set! v.final-newline? (string-suffix? "\n" text))
                (when new?
                  (set! v.true-name (true-name (visit-file-name v))))
                (record-disk! v disk bytes revision)))
            #t))
         (begin
           (message (string-append "Wrote " (abbreviate-file-name (visit-file-name v))))
           (run-hook after-save-hook b)
           #t))))

(def (save-buffer! (b : buffer)) => :boolean
  (let (v (buffer-visit b))
    (cond
     ((not v) (message (string-append (buffer-name b) " is not visiting a file")) #f)
     ((not (visit-editable? v))
      (message (string-append (buffer-name b) " is read-only (" (note-for (visit-encoding v)) "); not saved"))
      #f)
     ((and (not (buffer-modified? b)) (visit-disk v))
      (message "(No changes need to be saved)")
      #t)
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
                    (let (v (visit file-name: name true-name: truename identity: #f disk: #f hash: #f
                                   encoding: 'utf-8 bom?: #f line-ending: 'lf final-newline?: #f
                                   saved-revision: -1 changes: (new-source)))
                      (hash-put! (files-state-visits self) (text-of b) v)
                      v))
                : visit)
        (set! v.file-name name)
        (set! v.true-name truename)
        (record-disk! v #f #f -1)
        (set-buffer-setting! b default-directory (file-name-directory name))
        (rename-file-buffers! #f #f #f)
        (save! b v))))))

(implement Files files-state
  (find-file-noselect (lambda (self path) (visit-file! self path)))
  (text-visit (lambda (self t) (hash-get (files-state-visits self) t)))
  (save-buffer! (lambda (self b) (save-buffer! b)))
  (write-buffer! (lambda (self b path) (write-buffer! self b path))))

;;; Questions

;; Ask QUESTION until the answer is "yes" or "no" (Emacs yes-or-no-p).
(def (yes-or-no? (question : :string)) => :boolean
  (let lp ()
    (let (answer (read-string (string-append question "(yes or no) ")))
      (cond
       ((equal? answer "yes") #t)
       ((equal? answer "no") #f)
       (else (message "Please answer yes or no.") (lp))))))

;; The answers to save-some-buffers' question, by the key typed.
(def save-answers
  '(("y" . save) ("SPC" . save) ("n" . skip) ("DEL" . skip)
    ("!" . save-all) ("." . save-and-stop) ("q" . stop) ("RET" . stop)))

;; Ask whether to save B; one of save-answers' answers.
(def (ask-save (self : files-state) (b : buffer)) => :symbol
  (let (asked #f)
    (unwind-protect
      (:- (read-from-minibuffer
           (string-append "Save file " (abbreviate-file-name (buffer-file b)) "? (y, n, !, ., q) ")
           setup: (lambda ((p : Prompt))
                    (set! asked p)
                    (set! (files-state-answering self) (cons p (files-state-answering self)))
                    (set-node-keymap! (prompt-answer-node p) (files-state-answer-keymap self))))
          :symbol)
      (set! (files-state-answering self) (remq asked (files-state-answering self))))))

;; Offer each unsaved file buffer for saving, as Emacs's save-some-buffers.
(def (save-some-buffers! (self : files-state)) => :void
  (let lp ((rest (filter buffer-modified? (file-buffers))) (all? #f) (saved 0))
    (match rest
      ([] (message (if (fx= saved 0) "(No files need saving)"
                       (string-append "Saved " (number->string saved) " file" (if (fx= saved 1) "" "s")))))
      ([b . more]
       (let (answer (if all? 'save (ask-save self b)))
         (case answer
           ((save) (lp more all? (if (save-buffer! b) (fx1+ saved) saved)))
           ((save-all) (lp more #t (if (save-buffer! b) (fx1+ saved) saved)))
           ((save-and-stop) (lp [] all? (if (save-buffer! b) (fx1+ saved) saved)))
           ((skip) (lp more all? saved))
           (else (lp [] all? saved))))))))

;; The kill query: an unsaved file buffer asks first.
(def (kill-unsaved? (b : buffer)) => :boolean
  (or (not (buffer-modified? b))
      (yes-or-no? (string-append "Buffer " (buffer-name b) " modified; kill anyway? "))))

;;; Commands

;; The file name to visit, read with the picker from the current buffer's
;; folder; RET on a folder opens the picker there.
(def (read-file-to-visit (self : files-state) (question : :string)) => :string
  (let lp ((initial (abbreviate-file-name (buffer-default-directory (current-buffer)))))
    (let* ((from (buffer-default-directory (current-buffer)))
           (answer (completing-read question (file-table from)
                                    require-match: #f initial: initial history: 'file
                                    setup: (lambda ((p : Prompt))
                                             (wrap-picker-answer! p (files-state-picker-keymap self)))))
           (name (expand-file-name (:- answer :string) from))
           (stat (stat-file name)))
      (if (and stat (eq? (file-stat-kind stat) 'folder) (not (equal? (file-name-as-directory name) (expand-file-name initial from))))
        (lp (abbreviate-file-name (file-name-as-directory name)))
        name))))

(defplugin (files ctx)
  "Opens and saves files: C-x C-f, C-x C-s, C-x s, C-x C-w; the local disk as the file service."
  provides: [file-system-service files-service]
  requires: [commands-service input-service buffers-service layout-service settings-service
             minibuffer-service completion-service session-service]
  optional: [renderer-service completion-ui-service]
  (add-stylesheet 'rules "rules.css")
  (context-provide! ctx file-system-service
                    (FileSystem (new-local-disk (lambda () (path-expand "file-backups" (state-directory))))))
  (using (self (files-state visits: (make-hash-table-eq weak-keys: #t)
                            picker-keymap: (new-keymap) answer-keymap: (new-keymap) answering: [])
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
           ((buffer-modified? b) "*")
           (else #f)))))
    (context-add-kill-buffer-query! ctx 'files kill-unsaved?)
    (context-add-hook! ctx kill-buffer-hook 'files
      (lambda ((b : buffer))
        (when (buffer-visit b)
          (rename-file-buffers! b #f #f)
          (hash-remove! (files-state-visits self) (text-of b)))))
    (defcommand (find-file) "Visit a file, chosen with the file picker, in the selected view; a new name makes a new file on first save."
      (find-file (read-file-to-visit self "Find file: ")))
    (defcommand (save-buffer) "Save the current buffer to its file, if it changed."
      (save-buffer (current-buffer)))
    (defcommand (save-some-buffers) "Offer each unsaved file buffer for saving: y or SPC saves, n or DEL skips, ! saves the rest, . saves this one and stops, q or RET stops."
      (save-some-buffers! self))
    (defcommand (write-file) "Save the current buffer to another file, which it visits from then on."
      (let* ((b (current-buffer))
             (name (read-file-to-visit self "Write file: "))
             (stat (stat-file name)))
        (when (or (not stat) (eq? (file-stat-kind stat) 'folder)
                  (equal? (buffer-file b) name)
                  (yes-or-no? (string-append "File " (abbreviate-file-name name) " exists; overwrite? ")))
          (write-file b name))))
    (context-define-command! ctx 'file-picker-slash picker-slash!
      doc: "In the file picker: insert \"/\"; \"~/\" there jumps home."
      visible?: (lambda (c origin) #f))
    (context-define-command! ctx 'save-some-buffers-answer
      (lambda ()
        (let* ((event (last-command-event))
               (key (cond ((not (key-event? event)) "")
                          ((equal? (key-event-key event) " ") "SPC")
                          ((equal? (key-event-key event) "Backspace") "DEL")
                          ((equal? (key-event-key event) "Enter") "RET")
                          (else (key-event-key event))))
               (answer (assoc key save-answers)))
          (when (and answer (pair? (files-state-answering self)))
            (prompt-exit! (car (files-state-answering self)) (cdr answer) history-text: key))))
      doc: "Answer save-some-buffers' question with the key typed."
      visible?: (lambda (c origin) #f))
    (keymap-set-in ctx (files-state-picker-keymap self) "/" 'file-picker-slash)
    (for-each (lambda ((answer : :pair))
                (keymap-set-in ctx (files-state-answer-keymap self) (car answer) 'save-some-buffers-answer))
              save-answers)
    (keymap-set "C-x C-f" 'find-file)
    (keymap-set "C-x C-s" 'save-buffer)
    (keymap-set "C-x s" 'save-some-buffers)
    (keymap-set "C-x C-w" 'write-file)))
