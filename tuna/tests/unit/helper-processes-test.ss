;;; The process library: helpers' private socket folders, private Unix
;;; sockets and devices, a device writer that keeps order, and starting a
;;; program detached.
(import :std/test
        :tuna/lib/unix
        :tuna/lib/helper-processes)
(export helper-processes-test)

(def folder-count 0)

;; Call PROC with a new folder path under /tmp (not made), removing it and
;; what is in it afterwards.
(def (call-with-scratch-path (proc : :procedure)) => :t
  (set! folder-count (+ folder-count 1))
  (let (path (string-append "/tmp/tuna-helper-processes-test-" (number->string (current-process-id))
                            "-" (number->string folder-count)))
    (try
     (proc path)
     (finally
      (let remove ((path path))
        (when (file-exists? path)
          (if (eq? (file-info-type (file-info path #f)) 'directory)
            (begin
              (for-each (lambda (name) (remove (path-expand name path))) (directory-files path))
              (delete-directory path))
            (delete-file path))))))))

(def (mode-of (path : :string)) => :fixnum
  (fxand (file-info-mode (file-info path #f)) #o777))

(def (read-all-from (device : :t)) => :string
  (let ((buffer (make-u8vector 4 0))
        (out (open-output-u8vector)))
    (let lp ()
      (let (n (device-read-some device buffer))
        (when (fx> n 0)
          (write-subu8vector buffer 0 n out)
          (lp))))
    (utf8->string (get-output-u8vector out))))

(def helper-processes-test
  (test-suite "tuna/lib: helper processes"
    (test-case "a kind's socket folder is private, in the runtime folder or the override"
      (call-with-scratch-path
       (lambda (runtime)
         (create-directory runtime)
         (let (saved (getenv "XDG_RUNTIME_DIR" #f))
           (try
            (setenv "XDG_RUNTIME_DIR" runtime)
            (let (folder (helper-socket-directory "things"))
              (check folder => (path-expand "things" (path-expand "tuna" runtime)))
              (check (mode-of folder) => #o700)
              (check (mode-of (path-expand "tuna" runtime)) => #o700)
              (check (helper-socket-path folder "7") => (path-expand "7.sock" folder)))
            (finally (if saved (setenv "XDG_RUNTIME_DIR" saved) (setenv "XDG_RUNTIME_DIR")))))
         ;; An override is used as it is, made private.
         (let (override (path-expand "mine" runtime))
           (create-directory [path: override permissions: #o755])
           (check (mode-of override) => #o755)
           (check (helper-socket-directory "things" override) => override)
           (check (mode-of override) => #o700))
         ;; A link is not a private folder.
         (let (link (path-expand "link" runtime))
           (create-symbolic-link runtime link)
           (check-exception (helper-socket-directory "things" link) true)))))

    (test-case "a socket only its user may use carries bytes both ways, written in order without waiting"
      (call-with-scratch-path
       (lambda (folder)
         (make-private-directory folder)
         (let* ((path (helper-socket-path folder "s"))
                (listener (unix-listen path))
                (accepted #f)
                (acceptor (spawn (lambda () (set! accepted (unix-accept listener)))))
                (client (unix-connect path)))
           (check (mode-of path) => #o600)
           (thread-join! acceptor 5)
           (let* ((server accepted)
                  (buffer (make-u8vector 16 0)))
             (device-write-all server (string->utf8 "back"))
             (check (utf8->string (subu8vector buffer 0 (device-read-some client buffer))) => "back")
             (let (w (new-device-writer client 'test-writer))
               (for-each (lambda (piece) (device-writer-send! w (string->utf8 piece))) ["one " "two " "three"])
               (device-writer-close! w))
             ;; The writer ends the socket after what it sent: the reader sees it all, then the end.
             (check (read-all-from server) => "one two three")
             (close-device server)
             (close-device client)
             (close-device listener))))))

    (test-case "a helper starts detached, in a scope of its own when asked"
      (check (detached-command ["helper" "--socket" "s"] #f) => ["-f" "helper" "--socket" "s"])
      (check (detached-command ["helper"] "tuna-x-1")
             => ["-f" "systemd-run" "--user" "--scope" "--quiet" "--collect" "--unit=tuna-x-1" "helper"])
      (check (helper-leaves-scope? 'always) => #t)
      (check (helper-leaves-scope? 'never) => #f)
      (check (helper-leaves-scope? 'auto) => (in-systemd-unit?))
      (call-with-scratch-path
       (lambda (folder)
         (make-private-directory folder)
         (let (out (path-expand "out" folder))
           (launch-detached! ["/bin/sh" "-c" (string-append "printf %s \"$WORD\" > " out ".part && mv " out ".part " out)]
                             ["WORD=detached" "PATH=/usr/bin:/bin"] #f)
           ;; wait-for-socket waits for any path.
           (check (wait-for-socket out 5) => #t)
           (check (call-with-input-file out read-line) => "detached")
           (check (wait-for-socket (path-expand "missing" folder) 0.05) => #f)))))))
