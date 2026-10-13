;;; `tuna reload` from a terminal (docs/briefs/2026-10-configuration.md):
;;; each running Tuna listens on a Unix-domain socket of its own, and
;;; `tuna reload` asks every running Tuna of the user to reload and prints
;;; each one's report. This is program code beside tuna/boot.ss, outside
;;; the kernel and independent of every plugin, so it works when the
;;; user's input or display plugins are broken.
;;;
;;; Why a socket: it carries the report back to the terminal that asked,
;;; needs no network port, and only the user can reach it: the directory
;;; must be the user's own with mode 700, or neither side uses it, and
;;; each socket has mode 600. Every Tuna sharing the directory reloads,
;;; including test or development Tunas run with the same
;;; XDG_RUNTIME_DIR. The file is named after the process id, so
;;; several Tunas never share one. A file that nothing listens on is
;;; stale (its Tuna ended without deleting it, or its id was reused), and
;;; `tuna reload` deletes it. A signal and a pid file could neither answer
;;; the terminal nor tell a stale file from a reused process id.
;;;
;;; The protocol is one exchange per connection: the client sends
;;; "reload\n" and closes its side; Tuna answers "ok\n" or "failed\n"
;;; followed by the report, and closes.
prelude: :gerbil/core

(import (only-in :gerbil/runtime/thread spawn-thread)
        :std/io
        :std/net/address
        (only-in :std/os/pid getpid)
        (only-in :std/time/timeout timeout->deadline)
        :std/ffi
        (only-in :tuna/kernel exception-summary)
        :tuna/boot)
(export reply-time-limit
        control-directory
        control-socket-path
        control-server
        control-server-path
        start-control-server!
        stop-control-server!
        request-reloads)

;; Where the sockets are: $XDG_RUNTIME_DIR/tuna, or the state directory's
;; tuna/control when that variable is unset or relative.
(def (control-directory) => :string
  (let (runtime (getenv "XDG_RUNTIME_DIR" ""))
    (if (string-prefix? "/" runtime)
      (path-expand "tuna" runtime)
      (path-expand "tuna/control" (xdg-directory "XDG_STATE_HOME" ".local/state")))))

(def (control-socket-path (pid : :fixnum)) => :string
  (path-expand (string-append (number->string pid) ".sock") (control-directory)))

;; chmod(2) and getuid(2); Gerbil's libraries have neither.
(C-ffi-macrology)
(C-include "<sys/stat.h>" "<unistd.h>")
(def-C-lambda chmod-file (char-string int) int "chmod")
(def-C-lambda user-id () int "getuid")

;; Seconds `tuna reload` waits for each Tuna's answer.
(def reply-time-limit (make-parameter 30.))

;; Why DIRECTORY must not be used for control sockets, or #f: it must be
;; a directory owned by the user, with mode 700.
(def (directory-problem (directory : :string)) => (Maybe :string)
  (let (info (file-info directory #f))
    (and (not (and (eq? (file-info-type info) 'directory)
                   (eqv? (file-info-owner info) (user-id))
                   (fx= (fxand (file-info-mode info) #o777) #o700)))
         (string-append directory " is not a directory private to you (yours, mode 700), so "
                        "`tuna reload` does not use it."))))

;; A listening socket and the thread serving it.
(defstruct control-server ((listener : ServerSocket)
                           (path     : :string)
                           (thread   : :thread))
  final: #t)

;; Listen on this process's socket and serve each request on a thread of
;; its own, one at a time. RELOAD! runs a reload and returns (succeeded?
;; . report-text); it is called from that thread.
(def (start-control-server! (reload! : :procedure)) => control-server
  (let ((directory (control-directory))
        (path (control-socket-path (getpid))))
    (create-private-directory! directory)
    (cond ((directory-problem directory) => error))
    ;; Left by an earlier process with this id, which has ended.
    (when (file-exists? path)
      (delete-file path))
    (let (listener (unix-listen (UnixAddress path)))
      (chmod-file path #o600)
      (make-control-server listener path
                           (spawn-thread (lambda () (control-thread listener reload!))
                                         'tuna-control)))))

;; Stop listening, wait for the request being served, and delete the
;; socket. While waiting, WHILE-WAITING is called about every 0.1 s, so
;; the caller can answer a request that waits for it.
(def (stop-control-server! (server : control-server) (while-waiting : :procedure)) => :void
  (using (listener (control-server-listener server) : ServerSocket)
    (listener.close))
  (let wait ()
    (when (eq? (thread-join! (control-server-thread server) 0.1 'waiting) 'waiting)
      (while-waiting)
      (wait)))
  (when (file-exists? (control-server-path server))
    (delete-file (control-server-path server))))

;; DIRECTORY, created readable only by the user when missing.
(def (create-private-directory! (directory : :string)) => :void
  (unless (file-exists? directory)
    (create-directory* (path-directory (path-strip-trailing-directory-separator directory)))
    (create-directory (list path: directory permissions: #o700))))

(def (control-thread (listener : ServerSocket) (reload! : :procedure)) => :void
  (let loop ()
    ;; Accepting fails once the listener is closed.
    (let (client (with-catch (lambda (_) #f) (lambda () (listener.accept))))
      (when client
        (with-catch void (lambda () (serve-request! client reload!)))
        (loop)))))

(def (serve-request! (client : StreamSocket) (reload! : :procedure)) => :void
  (try
   (let (answer
         (if (equal? (read-request client) "reload")
           (match (with-catch (lambda (e) (cons #f (string-append "The reload failed: "
                                                                  (exception-summary e) "\n")))
                              reload!)
             ([succeeded? . text]
              (string-append (if succeeded? "ok\n" "failed\n") text)))
           "failed\nTuna understands only `reload`.\n"))
     (using (writer (client.writer) : Writer)
       (writer.write (string->utf8 answer))))
   (finally (client.close))))

;; The request line, without its newline; at most 64 bytes, within 5 s.
(def (read-request (client : StreamSocket)) => :string
  (client.set-input-timeout! (timeout->deadline 5))
  (using (reader (client.reader) : Reader)
    (let* ((buffer (make-u8vector 64))
           (n (let loop ((n 0))
                (if (fx= n 64)
                  n
                  (let (count (reader.read buffer n 64 0))
                    (if (or (fxzero? count)
                            (u8vector-index 10 buffer n (fx+ n count)))
                      (fx+ n count)
                      (loop (fx+ n count))))))))
      (car (string-split (utf8->string (subu8vector buffer 0 n)) #\newline)))))

;; The position of BYTE in VECTOR between START and END, or #f.
(def (u8vector-index (byte : :fixnum) (vector : :u8vector) (start : :fixnum) (end : :fixnum))
  => (Maybe :fixnum)
  (let loop ((i start))
    (cond
     ((fx= i end) #f)
     ((fx= (u8vector-ref vector i) byte) i)
     (else (loop (fx1+ i))))))

;;; `tuna reload`

;; Ask every running Tuna to reload and print each report to PORT.
;; Returns the exit status: 0 when at least one Tuna reloaded and none
;; failed, otherwise 1.
(def (request-reloads (port : :port)) => :fixnum
  (let* ((directory (control-directory))
         (problem (and (file-exists? directory) (directory-problem directory)))
         (pids (if (and (file-exists? directory) (not problem))
                 (filter-map socket-file-pid (directory-files directory))
                 []))
         (answers (filter-map (lambda ((pid : :fixnum)) (request-reload pid)) (list-sort < pids))))
    (cond
     (problem
      (display (string-append problem "\n") port)
      1)
     ((null? answers)
      (display "No running Tuna was found, so nothing was reloaded.\n" port)
      1)
     (else
      (for-each (lambda ((answer : :pair))
                  (when (pair? (cdr answers))
                    (display (string-append "Tuna process " (number->string (car answer)) ":\n") port))
                  (display (cddr answer) port))
                answers)
      (if (andmap cadr answers) 0 1)))))

;; The process id a socket file NAME is named after, or #f.
(def (socket-file-pid (name : :string)) => (Maybe :fixnum)
  (and (string-suffix? ".sock" name)
       (let (pid (string->number (substring name 0 (fx- (string-length name) 5))))
         (and (fixnum? pid) (fxpositive? pid) pid))))

;; Ask the Tuna with process id PID to reload: (pid succeeded? . text), or
;; #f when nothing listens on its socket, which is then deleted.
(def (request-reload (pid : :fixnum)) => (Maybe :pair)
  (let (path (control-socket-path pid))
    (match (with-catch (lambda (e) (cons 'error e))
                       (lambda () (unix-connect (UnixAddress path))))
      (['error . _]
       ;; A running Tuna accepts even while busy, so nothing listens:
       ;; the process ended, or its id now belongs to another process.
       (with-catch void (lambda () (delete-file path)))
       #f)
      (client
       (using (client : StreamSocket)
         (try
          (with-catch
           (lambda (e)
             (cons* pid #f (string-append "Tuna process " (number->string pid)
                                          " did not answer within " (seconds-text (reply-time-limit))
                                          "; it may be busy. " (exception-summary e) "\n")))
           (lambda ()
             (client.set-input-timeout! (timeout->deadline (reply-time-limit)))
             (client.set-output-timeout! (timeout->deadline (reply-time-limit)))
             (using (writer (client.writer) : Writer)
               (writer.write (string->utf8 "reload\n"))
               (writer.close))
             (let (answer (read-answer client))
               (match (string-index answer #\newline)
                 (#f (cons* pid #f (string-append "Tuna process " (number->string pid)
                                                  " ended its answer early.\n")))
                 (end (cons* pid (equal? (substring answer 0 end) "ok")
                             (substring answer (fx1+ end) (string-length answer))))))))
          (finally (client.close))))))))

;; Everything CLIENT sends until it closes, as text.
(def (read-answer (client : StreamSocket)) => :string
  (using (reader (client.reader) : Reader)
    (let loop ((chunks []))
      (let* ((buffer (make-u8vector 4096))
             (n (reader.read buffer 0 4096 0)))
        (if (fxzero? n)
          (utf8->string (apply u8vector-append (reverse chunks)))
          (loop (cons (subu8vector buffer 0 n) chunks)))))))
