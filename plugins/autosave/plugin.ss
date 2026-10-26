#lang :tuna/prelude
;;; Autosave (live tier; ADR 5): keeps unsaved buffer text in
;;; $XDG_STATE_HOME/tuna/autosave/, one file per buffer, and the session slot
;;; `buffers`, which lists each buffer's name, point, and autosave file, so
;;; buffers come back with their text and points on start.
;;;
;;; It keeps buffers that are one text node. Buffers built as trees belong
;;; to the plugins that build them, and internal buffers are skipped. A
;;; buffer's file is rewritten only when its text changed; files of buffers
;;; that are gone are deleted.
;;;
;;; A buffer visiting a file (the files contract) is kept with its
;;; buffer-recovery-data, and its text only while it has unsaved changes,
;;; in a file named after the file's true name ("#%2Fhome%2Fnotes.txt#",
;;; never beside the file itself). That copy goes as soon as the buffer is
;;; saved or killed, and at the next autosave once the text is back to
;;; what was saved. On start, recover-file-buffer makes the buffer again:
;;; with the copy as unsaved text, or read from its file without one.
;;; Without a files plugin, the copy comes back as a plain buffer, so its
;;; text is not lost.

(import (only-in :gerbil/runtime/hash HashTable)
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/session/contract
        :tuna/plugins/files/contract)
(export autosave
        autosave-file-name)

;; What was last written: text -> (file . chars revision); and each file
;; buffer's last entry, by text.
(defclass autosave-state ((written : HashTable)
                          (file-entries : HashTable))
  final: #t)

(def (safe-char? (c : :char)) => :boolean
  (or (char<=? #\a c #\z) (char<=? #\A c #\Z) (char<=? #\0 c #\9) (char=? c #\-) (char=? c #\_)))

;; NAME as a file name: ASCII letters, digits, `-` and `_` stay; every
;; other character becomes %XX for each byte of its UTF-8 encoding. A
;; buffer's copy is named so.
(def (autosave-file-name (name : :string)) => :string
  (call-with-output-string ""
    (lambda (port)
      (string-for-each
       (lambda (c)
         (if (safe-char? c)
           (write-char c port)
           (let (bytes (string->utf8 (string c)))
             (let lp ((i 0))
               (when (fx< i (u8vector-length bytes))
                 (let (byte (u8vector-ref bytes i))
                   (write-char #\% port)
                   (when (fx< byte 16) (write-char #\0 port))
                   (display (string-upcase (number->string byte 16)) port))
                 (lp (fx1+ i)))))))
       name))))

;; The name of the copy of a file buffer's text, for the file whose true
;; name is TRUENAME, as Emacs's #notes.txt#; no buffer's copy has a "#".
(def (file-copy-name (truename : :string)) => :string
  (string-append "#" (autosave-file-name truename) "#"))

;; Whether NAME could be a file-copy-name, so a session cannot point
;; outside the autosave directory.
(def (file-copy-name? (name : :t)) => :boolean
  (and (string? name)
       (fx> (string-length name) 2)
       (string-prefix? "#" name)
       (string-suffix? "#" name)
       (andmap (lambda (c) (or (safe-char? c) (char=? c #\%)))
               (string->list (substring name 1 (fx1- (string-length name)))))))

(def (autosave-directory) => :string
  (path-expand "autosave" (state-directory)))

(def (kept? (b : buffer)) => :boolean
  (and (not (internal-buffer? b)) (text-node? (buffer-root b))))

(def (buffer-text (b : buffer)) => text
  (text-node-content (buffer-root b)))

;; B's point: the selected view's when it shows B.
(def (current-point (b : buffer)) => :fixnum
  (let (v (selected-view))
    (if (eq? (view-showing v) b)
      (view-point v)
      (buffer-point b))))

;; Write each kept buffer whose text changed, delete stale files, and
;; return the slot's data: (NAME POINT FILE ROOT-ID RECOVERY) for each
;; kept buffer. FILE is its copy, #f for a file buffer with no unsaved
;; changes; RECOVERY is a file buffer's buffer-recovery-data, else #f.
;; While no plugin visits files (the files plugin is off, as when Tuna
;; stops and its plugins turn off one by one), a buffer that visited a
;; file keeps its last entry and copy instead of becoming a plain buffer.
(def (save-buffers! (self : autosave-state)) => :list
  (let ((directory (autosave-directory))
        (written (make-hash-table-eq))
        (file-entries (make-hash-table-eq))
        (visiting? (and (service-provider files-service) #t)))
    (create-directory* directory)
    (let (entries
          (map (lambda ((b : buffer))
                 (let* ((t (buffer-text b))
                        (kept (and (not visiting?) (hash-get self.file-entries t))))
                   (if kept
                     (let (stamp (hash-get self.written t))
                       (when stamp (hash-put! written t stamp))
                       (hash-put! file-entries t kept)
                       kept)
                     (let* ((v (buffer-visit b))
                            (file (cond
                                   ((not v) (autosave-file-name (buffer-name b)))
                                   ((buffer-modified? b) (file-copy-name (visit-true-name v)))
                                   (else #f)))
                            (entry [(buffer-name b) (current-point b) file (node-id (buffer-root b))
                                    (and v (buffer-recovery-data b))]))
                       (when file
                         (let ((stamp (cons file (text-chars-revision t)))
                               (path (path-expand file directory)))
                           (unless (and (equal? (hash-get self.written t) stamp) (file-exists? path))
                             (write-file-atomically! path (lambda (port) (display (text-string t) port))))
                           (hash-put! written t stamp)))
                       (when v (hash-put! file-entries t entry))
                       entry))))
               (filter kept? (buffer-list))))
      (set! self.written written)
      (set! self.file-entries file-entries)
      (let (files (filter-map caddr entries))
        (for-each (lambda ((file : :string))
                    (unless (member file files)
                      (delete-file (path-expand file directory))))
                  (directory-files directory)))
      entries)))

(def (read-text-file (path : :string)) => :string
  (let (port (open-input-file [path: path char-encoding: 'UTF-8]))
    (unwind-protect
      (let (content (read-line port #f))
        (if (eof-object? content) "" content))
      (close-port port))))

;; Delete the copy of B's text, if any, as B was saved or killed: the one
;; autosave last wrote, and a file buffer's own (restored, not yet
;; written again).
(def (forget-copy! (self : autosave-state) (b : buffer)) => :void
  (when (kept? b)
    (let* ((t (buffer-text b))
           (stamp (hash-get self.written t))
           (v (buffer-visit b)))
      (hash-remove! self.written t)
      (for-each (lambda ((file : :string))
                  (let (path (path-expand file (autosave-directory)))
                    (when (file-exists? path)
                      (delete-file path))))
                (append (if stamp [(car stamp)] [])
                        (if v [(file-copy-name (visit-true-name v))] []))))))

;; Bring back the buffers DATA lists. A buffer of that name that is one
;; empty text node receives the text (*scratch*, made at startup); one
;; that already holds text keeps it; otherwise a new buffer is made.
;; File buffers come back through the files contract.
;; Root ids are recorded for layout references; rebuilt roots get fresh ids,
;; so layout restore falls back to their root when that id is absent.
(def (restore-buffers! (self : autosave-state) (data : :t)) => :void
  (let (directory (autosave-directory))
    (for-each
      (lambda (entry)
        (match entry
          ([(? string? name) (? fixnum? position) file (? fixnum? root-id) recovery]
           (with-catch
            (lambda (e)
              (message (string-append "Could not restore buffer " name ": " (exception-summary e))))
            (lambda ()
              (cond
               (recovery (restore-file-buffer! self name position file recovery))
               ;; The file name must be the one the name maps to, so the
               ;; session cannot point outside the autosave directory.
               ((and (string? file) (string=? file (autosave-file-name name))
                     (file-exists? (path-expand file directory)))
                (restore-buffer! self name position file (read-text-file (path-expand file directory))))
               (else
                (message (string-append "No autosaved text for buffer " name)))))))
          (else (void))))
      (if (list? data) data []))))

;; Bring back the file buffer NAME: its unsaved text from FILE, if there
;; is such a copy, and its file from RECOVERY.
(def (restore-file-buffer! (self : autosave-state) (name : :string) (position : :fixnum) (file : :t)
                           (recovery : :t))
  => :void
  (let* ((path (and (file-copy-name? file) (path-expand file (autosave-directory))))
         (content (and path (file-exists? path) (read-text-file path))))
    (cond
     ((service-provider files-service)
      (let (b (recover-file-buffer recovery content))
        (if b
          (set-buffer-point! b (fxmax 1 (fxmin position (fx1+ (text-size (buffer-text b))))))
          (message (string-append "Not restoring buffer " name ": its file is not there")))))
     (content
      (restore-buffer! self name position (:- file :string) content))
     (else
      (message (string-append "Not restoring buffer " name ": no plugin visits files"))))))

(def (restore-buffer! (self : autosave-state) (name : :string) (position : :fixnum) (file : :string)
                      (content : :string))
  => :void
  (let (existing (get-buffer name))
    (cond
     ((not existing)
      (let (b (new-buffer name (new-text-node (new-text content))))
        (add-buffer! b)
        (set-buffer-point! b position)
        (hash-put! self.written (buffer-text b) (cons file (text-chars-revision (buffer-text b))))))
     ((and (kept? existing) (fx> (text-size (buffer-text existing)) 0))
      (void))
     ((kept? existing)
      (let (t (buffer-text existing))
        (text-replace! t 1 (fx1+ (text-size t)) content)
        (text-clear-undo! t)
        (set-buffer-point! existing position)
        (let (v (selected-view))
          (when (eq? (view-showing v) existing)
            (set-view-point! v position)))
        (hash-put! self.written t (cons file (text-chars-revision t)))))
     (else
      (message (string-append "Not restoring buffer " name ": a buffer with that name is not plain text"))))))

(defplugin (autosave ctx)
  "Autosaves unsaved buffer text, of file buffers too; restores buffers, their text, their files, and their points on start."
  requires: [buffers-service session-service]
  optional: [files-service file-system-service]
  (using (self (autosave-state written: (make-hash-table-eq) file-entries: (make-hash-table-eq)) : autosave-state)
    (context-add-hook! ctx after-save-hook 'autosave (lambda ((b : buffer)) (forget-copy! self b)))
    (context-add-hook! ctx kill-buffer-hook 'autosave (lambda ((b : buffer)) (forget-copy! self b)))
    (context-add-session-slot! ctx 'buffers
                               version: 2
                               save: (lambda () (save-buffers! self))
                               restore: (lambda (data) (restore-buffers! self data)))))
