;;; The local disk, the file service's default provider.
;;;
;;; Saving (write-file-bytes): a symbolic link saves through to its target.
;;; The new contents go to a temporary file in the target's folder, which
;;; is flushed to disk, given the file's mode and owner, and renamed over
;;; the file; then the folder is flushed, so a crash leaves the old file or
;;; the new one. When renaming would change what the file is, the file is
;;; written in place instead, after a copy of it is kept as a backup until
;;; the write is flushed: when it has other hard links, when its owner or
;;; group cannot be given to a new file, and when its folder takes no new
;;; files (Neovim's backupcopy=auto rule). The backup goes beside the file,
;;; or into BACKUP-FOLDER when its folder takes no new files.
;;;
;;; Gambit has no realpath(3), chmod(2), chown(2), nanosecond modification
;;; times or a way to flush a folder, so this module calls them itself, as
;;; tuna/control.ss does chmod.
prelude: :gerbil/core

(import :std/ffi
        (only-in :std/os/pid getpid)
        :std/interface
        :tuna/plugins/files/contract)
(export local-disk new-local-disk)

(C-ffi-macrology)
(C-include "<stdlib.h>" "<limits.h>" "<sys/types.h>" "<sys/stat.h>" "<fcntl.h>" "<unistd.h>" "<errno.h>")
(C-declare "static char tuna_files_true_name[PATH_MAX];")
;; PATH with every link resolved, or #f when that fails (as for a path
;; that does not exist).
(def-C-lambda resolved-path (char-string) char-string
  "___return(realpath(___arg1, tuna_files_true_name));")
(def-C-lambda change-mode (char-string int) int
  "___return(chmod(___arg1, ___arg2) < 0 ? -errno : 0);")
(def-C-lambda change-owner (char-string int int) int
  "___return(chown(___arg1, ___arg2, ___arg3) < 0 ? -errno : 0);")
;; PATH's modification time in nanoseconds since 1970 (following links),
;; or -1.
(def-C-lambda modification-nanoseconds (char-string) int64
  "struct stat s;
   ___return(stat(___arg1, &s) < 0 ? -1 : (___S64)s.st_mtim.tv_sec * 1000000000LL + s.st_mtim.tv_nsec);")
;; Flush folder PATH's entries to disk: 0, or -errno.
(def-C-lambda sync-folder (char-string) int
  "int fd = open(___arg1, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
   int r = 0;
   if (fd < 0) r = -errno;
   else { if (fsync(fd) < 0) r = -errno; close(fd); }
   ___return(r);")

(defclass local-disk ((backup-folder : :procedure)) final: #t)

;; BACKUP-FOLDER returns the folder for backups of files whose own folder
;; takes no new files.
(def (new-local-disk (backup-folder : :procedure)) => local-disk
  (local-disk backup-folder: backup-folder))

(def (info->stat (path : :string) (info : :t)) => file-stat
  (let (nanoseconds (modification-nanoseconds path))
    (make-file-stat (case (file-info-type info) ((regular) 'file) ((directory) 'folder) (else 'other))
                    (file-info-size info)
                    (if (< nanoseconds 0)
                      (* 1000000000 (inexact->exact (floor (time->seconds (file-info-last-modification-time info)))))
                      nanoseconds)
                    (file-info-mode info)
                    (file-info-owner info)
                    (file-info-group info)
                    (file-info-number-of-links info)
                    (cons (file-info-device info) (file-info-inode info)))))

(def (stat-path (path : :string)) => (Maybe file-stat)
  (let (info (with-catch (lambda (e) #f) (lambda () (file-info path #t))))
    (and info (info->stat path info))))

(def (symbolic-link? (path : :string)) => :boolean
  (let (info (with-catch (lambda (e) #f) (lambda () (file-info path #f))))
    (and info (eq? (file-info-type info) 'symbolic-link))))

(def (read-bytes (path : :string)) => :u8vector
  (call-with-input-file path
    (lambda (port)
      (let lp ((chunks []))
        (let* ((chunk (make-u8vector 65536))
               (n (read-subu8vector chunk 0 65536 port)))
          (if (fx= n 0)
            (apply u8vector-append (reverse chunks))
            (lp (cons (subu8vector chunk 0 n) chunks))))))))

;; Write BYTES to the open PORT's file, flush it to disk and close it.
(def (write-and-flush! (port : :t) (bytes : :u8vector)) => :void
  (unwind-protect
    (begin
      (write-subu8vector bytes 0 (u8vector-length bytes) port)
      ;; Level 1 makes Gambit call fsync(2) (lib/os_io.c).
      (force-output port 1))
    (close-port port)))

(def temporary-counter 0)

;; A new file name in FOLDER for a temporary copy of the file named BASE.
(def (temporary-name (folder : :string) (base : :string) (what : :string)) => :string
  (set! temporary-counter (fx1+ temporary-counter))
  (string-append folder "." base "." what "-" (number->string (getpid))
                 "-" (number->string temporary-counter)))

;; Create a file in FOLDER for BASE with BYTES, flushed, or #f when the
;; folder takes no new files.
(def (write-temporary (folder : :string) (base : :string) (bytes : :u8vector)) => (Maybe :string)
  (let* ((name (temporary-name folder base "tuna-save"))
         (port (with-catch (lambda (e) #f)
                 (lambda () (open-output-file [path: name create: #t permissions: #o600])))))
    (and port
         (begin
           (with-catch (lambda (e) (delete-file name) (raise e))
             (lambda () (write-and-flush! port bytes)))
           name))))

(def (check-folder-synced! (folder : :string)) => :void
  (let (result (sync-folder folder))
    (unless (fx= result 0)
      (error "Could not flush the folder to disk" folder result))))

;; Give the temporary file NAME the mode and owner of OLD; whether it could.
(def (copy-attributes! (name : :string) (old : file-stat)) => :boolean
  (let (now (stat-path name))
    (and now
         (fx= 0 (change-mode name (fxand (file-stat-mode old) #o7777)))
         (or (and (fx= (file-stat-owner now) (file-stat-owner old))
                  (fx= (file-stat-group now) (file-stat-group old)))
             (fx= 0 (change-owner name (file-stat-owner old) (file-stat-group old))))
         ;; chown(2) may clear set-user-id bits: set the mode again.
         (fx= 0 (change-mode name (fxand (file-stat-mode old) #o7777))))))

;; Write BYTES over TARGET in place, after copying it to a backup that is
;; removed once the new contents are on disk.
(def (write-in-place! (self : local-disk) (target : :string) (bytes : :u8vector)) => :void
  (let* ((folder (file-name-directory target))
         (base (file-name-nondirectory target))
         (backup (let (beside (temporary-name folder base "tuna-backup"))
                   (if (with-catch (lambda (e) #f) (lambda () (copy-file target beside) #t))
                     beside
                     (let ((elsewhere (temporary-name (file-name-as-directory ((local-disk-backup-folder self)))
                                                      base "tuna-backup")))
                       (create-directory* (file-name-directory elsewhere))
                       (copy-file target elsewhere)
                       elsewhere)))))
    (write-and-flush! (open-output-file [path: target create: #f truncate: #t]) bytes)
    (delete-file backup)))

(def (create-directory* (folder : :string)) => :void
  (unless (file-exists? folder)
    (create-directory* (file-name-directory (substring folder 0 (fx1- (string-length folder)))))
    (create-directory folder)))

(def (write-path! (self : local-disk) (path : :string) (bytes : :u8vector)) => file-stat
  (let* ((target (if (symbolic-link? path) (or (resolved-path path) path) path))
         (folder (file-name-directory target))
         (base (file-name-nondirectory target))
         (old (stat-path target)))
    (unless (file-exists? folder)
      (error "No such folder" folder))
    (when (and old (not (eq? (file-stat-kind old) 'file)))
      (error "Not a regular file" target))
    (cond
     ((and old (fx> (file-stat-links old) 1))
      (write-in-place! self target bytes))
     ((write-temporary folder base bytes)
      => (lambda ((temporary : :string))
           (if (or (not old) (copy-attributes! temporary old))
             (begin
               (rename-file temporary target)
               (check-folder-synced! folder))
             (begin
               (delete-file temporary)
               (write-in-place! self target bytes)))))
     (old (write-in-place! self target bytes))
     (else (error "Cannot create a file in this folder" folder)))
    (or (stat-path target) (error "The file is gone after writing it" target))))

(def (folder-entries (path : :string)) => :list
  (let (folder (file-name-as-directory path))
    (filter-map (lambda ((name : :string))
                  (let (stat (stat-path (string-append folder name)))
                    (and stat (make-folder-entry name stat))))
                (filter (lambda ((name : :string)) (not (member name '("." ".."))))
                        (directory-files [path: path ignore-hidden: #f])))))

(def (resolve-true-name (path : :string)) => :string
  (or (resolved-path path)
      (let (folder (resolved-path (file-name-directory path)))
        (if folder
          (string-append (file-name-as-directory folder) (file-name-nondirectory path))
          path))))

(implement FileSystem local-disk
  (stat-file (lambda (self path) (stat-path path)))
  (read-file-bytes (lambda (self path) (read-bytes path)))
  (write-file-bytes (lambda (self path bytes) (write-path! self path bytes)))
  (list-folder (lambda (self path) (folder-entries path)))
  (true-name (lambda (self path) (resolve-true-name path))))
