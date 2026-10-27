;;; Running terminal helpers in tests: a private folder for their sockets,
;;; a helper's connection read on a thread of the test's own, and stopping
;;; every process a test started, by its exact pid.
(import :tuna/plugins/terminal/io
        :tuna/plugins/terminal/protocol
        :tuna/plugins/terminal/connection
        (rename-in :gerbil-libghostty/ghostty (terminal? ghostty-terminal?)))
(export call-with-test-folder
        pid-alive?
        kill-pid!
        test-environment
        start-test-helper
        (struct-out test-client)
        connect-test-client
        test-client-text
        wait-for)

(def folder-count 0)

;; Call PROC with a new private folder, removed afterwards with what is in
;; it. Helpers an earlier test run left behind, when it was killed before
;; it could stop them, are stopped first.
(def (call-with-test-folder (proc : :procedure)) => :t
  (stop-orphan-helpers!)
  (set! folder-count (+ folder-count 1))
  (let (folder (string-append "/tmp/tuna-terminal-test-" (number->string (current-process-id))
                              "-" (number->string folder-count)))
    (make-private-directory folder)
    (try
     (proc folder)
     (finally
      (for-each (lambda (name) (with-catch void (lambda () (delete-file (path-expand name folder)))))
                (directory-files folder))
      (with-catch void (lambda () (delete-directory folder)))))))

;; Stop, by its pid, each helper started for a test run whose process is
;; gone: its command line names /tmp/tuna-terminal-test-PID-N/.
(def (stop-orphan-helpers!) => :void
  (for-each
   (lambda (name)
     (let (helper (string->number name))
       (when helper
         (let* ((cmd (with-catch (lambda (e) #f)
                                 (lambda () (call-with-input-file (string-append "/proc/" name "/cmdline") read-line))))
                (prefix "/tmp/tuna-terminal-test-")
                (at (and (string? cmd) (string-contains cmd "tuna-terminal-helper") (string-contains cmd prefix))))
           (when at
             (let* ((rest (substring cmd (+ at (string-length prefix)) (string-length cmd)))
                    (dash (string-index rest #\-))
                    (owner (and dash (string->number (substring rest 0 dash)))))
               (when (and owner (not (pid-alive? owner)))
                 (kill-pid! helper))))))))
   (directory-files "/proc")))

(def (pid-alive? (pid : :fixnum)) => :boolean
  (and (fx> pid 0) (file-exists? (string-append "/proc/" (number->string pid)))
       ;; A zombie has ended.
       (not (with-catch (lambda (e) #f)
                        (lambda ()
                          (let (stat (call-with-input-file (string-append "/proc/" (number->string pid) "/stat")
                                       read-line))
                            (let (close (string-rindex stat #\)))
                              (and close (char=? (string-ref stat (+ close 2)) #\Z)))))))))

;; Stop PID with SIGKILL unless it has ended.
(def (kill-pid! (pid : :fixnum)) => :void
  (when (pid-alive? pid)
    (signal-group pid 9)))

(def test-environment
  ["PATH=/usr/bin:/bin" "TERM=xterm-256color" "HOME=/tmp" "LANG=C.UTF-8" "PS1=$ "])

;; Start a helper in FOLDER, named NAME, running PROGRAM; returns its socket
;; path once it is there.
(def (start-test-helper (folder : :string) (name : :string) (program : :list)
                        columns: (columns : :fixnum := 80) rows: (rows : :fixnum := 24))
  => :string
  (let (socket (path-expand (string-append name ".sock") folder))
    (launch-helper! (make-helper-launch default-helper-path socket columns rows 1000000 folder
                                        (path-expand (string-append name ".log") folder)
                                        program test-environment #f))
    (unless (wait-for-socket socket 5) (error "The test helper did not start" name))
    socket))

;; A connection read on a thread: what it received, kept in a mirror.
(defclass test-client ((connection : :t)
                       (hello :? :t)
                       (mirror :? :t)
                       (frames : :list)          ; types received, newest first
                       (status :? :fixnum)
                       (refused? : :boolean)
                       (ended? : :boolean))
  final: #t)

(def (connect-test-client (socket : :string)) => test-client
  (let* ((c (open-connection socket))
         (client (test-client connection: c hello: #f mirror: #f frames: [] status: #f refused?: #f ended?: #f)))
    (spawn (lambda ()
             (let ((reader (new-frame-reader))
                   (buffer (make-u8vector 65536 0)))
               (let lp ()
                 (let (frames (read-frames (connection-device c) reader buffer))
                   (if frames
                     (begin
                       (for-each (cut receive! client <>) frames)
                       (lp))
                     (set! (test-client-ended? client) #t)))))))
    client))

(def (receive! (client : test-client) (f : frame)) => :void
  (set! client.frames (cons (frame-type f) client.frames))
  (case (frame-type f)
    ((hello) (set! client.hello (parse-helper-hello (frame-payload f))))
    ((snapshot) (set! client.mirror (snapshot-bytes->terminal (frame-payload f))))
    ((output) (terminal-write! client.mirror (frame-payload f)))
    ((exit) (set! client.status (parse-exit (frame-payload f))))
    ((refused) (set! client.refused? #t))
    (else (void))))

(def (test-client-text (client : test-client)) => :string
  (let (mirror (test-client-mirror client))
    (if mirror (terminal->plain-text mirror) "")))

;; Wait up to SECONDS for (READY?): whether it became true.
(def (wait-for (ready? : :procedure) (seconds : :real := 5)) => :boolean
  (let lp ((left seconds))
    (cond
     ((ready?) #t)
     ((<= left 0) #f)
     (else (thread-sleep! 0.02) (lp (- left 0.02))))))
