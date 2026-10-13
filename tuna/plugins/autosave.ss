;;; Autosave (live tier; ADR 5): keeps unsaved buffer text in
;;; $XDG_STATE_HOME/tuna/autosave/, one file per buffer, and the session slot
;;; `buffers`, which lists each buffer's name, point, and autosave file, so
;;; buffers come back with their text and points on start.
;;;
;;; It keeps buffers that are one text node. Buffers built as trees belong
;;; to the plugins that build them, and internal buffers are skipped. A
;;; buffer's file is rewritten only when its text changed; files of buffers
;;; that are gone are deleted.
prelude: :gerbil/core

(import (only-in :gerbil/runtime/hash HashTable)
        :tuna/kernel
        :tuna/services/buffers
        :tuna/services/session)
(export autosave-plugin
        autosave-file-name)

;; What was last written: text -> (file . chars revision).
(defclass autosave ((written : HashTable))
  final: #t)

;; NAME as a file name: ASCII letters, digits, `-` and `_` stay; every
;; other character becomes %XX for each byte of its UTF-8 encoding.
(def (autosave-file-name (name : :string)) => :string
  (call-with-output-string ""
    (lambda (port)
      (string-for-each
       (lambda (c)
         (if (or (char<=? #\a c #\z) (char<=? #\A c #\Z) (char<=? #\0 c #\9)
                 (memv c '(#\- #\_)))
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
;; return the slot's data: (NAME POINT FILE) for each kept buffer.
(def (save-buffers! (self : autosave)) => :list
  (let ((directory (autosave-directory))
        (written (make-hash-table-eq)))
    (create-directory* directory)
    (let (entries
          (map (lambda ((b : buffer))
                 (let* ((t (buffer-text b))
                        (file (autosave-file-name (buffer-name b)))
                        (stamp (cons file (text-chars-revision t)))
                        (path (path-expand file directory)))
                   (unless (and (equal? (hash-get self.written t) stamp) (file-exists? path))
                     (write-file-atomically! path (lambda (port) (display (text-string t) port))))
                   (hash-put! written t stamp)
                   [(buffer-name b) (current-point b) file]))
               (filter kept? (buffer-list))))
      (set! self.written written)
      (let (files (map caddr entries))
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

;; Bring back the buffers DATA lists. A buffer of that name that is one
;; text node receives the text (*scratch*, made at startup); otherwise a
;; new buffer is made.
(def (restore-buffers! (self : autosave) (data : :t)) => :void
  (let (directory (autosave-directory))
    (for-each
      (lambda (entry)
        (match entry
          ([(? string? name) (? fixnum? position) (? string? file)]
           (let (path (path-expand file directory))
             ;; The file name must be the one the name maps to, so the
             ;; session cannot point outside the autosave directory.
             (if (and (string=? file (autosave-file-name name)) (file-exists? path))
               (restore-buffer! self name position file (read-text-file path))
               (message (string-append "No autosaved text for buffer " name)))))
          (else (void))))
      (if (list? data) data []))))

(def (restore-buffer! (self : autosave) (name : :string) (position : :fixnum) (file : :string)
                      (content : :string))
  => :void
  (let (existing (get-buffer name))
    (cond
     ((not existing)
      (let (b (new-buffer name (new-text-node (new-text content))))
        (add-buffer! b)
        (set-buffer-point! b position)
        (hash-put! self.written (buffer-text b) (cons file (text-chars-revision (buffer-text b))))))
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

(defplugin (autosave-plugin ctx)
  "Autosaves unsaved buffer text; restores buffers, their text, and their points on start."
  requires: [buffers-service session-service]
  (using (self (autosave written: (make-hash-table-eq)) : autosave)
    (context-add-session-slot! ctx 'buffers
                               version: 1
                               save: (lambda () (save-buffers! self))
                               restore: (lambda (data) (restore-buffers! self data)))))
