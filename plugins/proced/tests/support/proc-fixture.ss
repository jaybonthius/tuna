;;; A stand-in for /proc for the proced plugin's tests and benchmarks: a
;;; directory holding PID/stat files in Linux's format.
(import :std/misc/ports)
(export make-proc-fixture
        write-process!
        remove-process!
        delete-proc-fixture)

;; A new empty fixture directory under TMPDIR.
(def (make-proc-fixture)
  (let (root (path-expand (string-append "tuna-proc-" (number->string (random-integer 1000000000)))
                          (getenv "TMPDIR" "/tmp")))
    (create-directory* root)
    root))

;; Write PID's stat under ROOT, replacing it whole (written aside, then
;; renamed), so a reader never sees half of it.
(def (write-process! root pid command: (command "sleep") state: (state "S") ticks: (ticks 0) rss: (rss 256))
  (let* ((directory (path-expand (number->string pid) root))
         (path (path-expand "stat" directory))
         (aside (string-append path ".new")))
    (create-directory* directory)
    (write-file-string aside
                       (string-append (number->string pid) " (" command ") " state
                                      " 1 1 1 0 -1 4194560 0 0 0 0 "
                                      (number->string ticks) " 0 0 0 20 0 1 0 100 1000000 "
                                      (number->string rss) " 18446744073709551615 1 1 0 0 0\n"))
    (rename-file aside path)))

(def (remove-process! root pid)
  (delete-file-or-directory (path-expand (number->string pid) root) #t))

(def (delete-proc-fixture root)
  (when (file-exists? root)
    (delete-file-or-directory root #t)))
