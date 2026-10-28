;;; Helper processes (ADR 18's process library): small programs that live
;;; outside Tuna, so what they hold (a terminal's program, an agent) goes
;;; on while Tuna restarts, and that Tuna talks to over a private Unix
;;; socket (unix.ss). A library (ADR 12): no editor state.
;;;
;;; A helper is started through `setsid -f`, so it is in a session of its
;;; own and Tuna does not wait for it, and, when Tuna runs in a systemd
;;; scope or service (`systemd-run --scope`, a desktop terminal's scope, or
;;; Tuna as a user service), through `systemd-run --user --scope` too, into
;;; a scope of its own, since a unit's processes all die with it. The
;;; helper itself then calls `start-session` and `redirect-standard-ports`.
;;;
;;; Its socket lives in a private folder for its kind of helper,
;;; $XDG_RUNTIME_DIR/tuna/KIND (mode 0700, checked), one socket per helper.
;;;
;;; A helper that runs a program on plain pipes needs nothing more from
;;; here: Gambit's `open-process` with `stdin-redirection: #t` and
;;; `stdout-redirection: #t` gives the program's input and output as one
;;; port, and `stderr-redirection: #f` leaves its standard error the
;;; helper's own, which `redirect-standard-ports` sent to the helper's log
;;; file, where the helper reads it once the program has ended. Such a
;;; helper must not reset SIGCHLD (as the terminal helper does for its
;;; own fork), since Gambit's `process-status` needs it.
;;;
;;; Tuna's side writes to a helper through a device writer, a thread of
;;; its own, in order, so the editor never waits on the socket.
prelude: :gerbil/core

(import :tuna/lib/unix)
(export helper-socket-directory
        helper-socket-path
        in-systemd-unit?
        helper-leaves-scope?
        detached-command
        launch-detached!
        wait-for-socket
        device-writer
        device-writer?
        new-device-writer
        device-writer-send!
        device-writer-close!)

;; The private folder holding the sockets of helpers of KIND (such as
;; "terminals"): OVERRIDE when it is not "", else $XDG_RUNTIME_DIR/tuna/KIND
;; (/tmp/tuna-UID/KIND without a runtime folder); made, and made private,
;; when needed.
(def (helper-socket-directory (kind : :string) (override : :string := "")) => :string
  (if (not (string-empty? override))
    (begin (make-private-directory override) override)
    (let* ((runtime (getenv "XDG_RUNTIME_DIR" #f))
           (base (if (and runtime (not (string-empty? runtime)))
                   (path-expand "tuna" runtime)
                   (string-append "/tmp/tuna-" (number->string (current-user-id)))))
           (folder (path-expand kind base)))
      (make-private-directory base)
      (make-private-directory folder)
      folder)))

;; The socket of helper ID in DIRECTORY.
(def (helper-socket-path (directory : :string) (id : :string)) => :string
  (path-expand (string-append id ".sock") directory))

;; Whether this process runs in a systemd scope or service, which kills
;; every process in it when it stops (a service's default KillMode).
(def (in-systemd-unit?) => :boolean
  (:- (with-catch
       (lambda (e) #f)
       (lambda ()
         (let (lines (call-with-input-file "/proc/self/cgroup" (lambda (port) (read-all port read-line))))
           (and (find (lambda ((line : :string)) (or (string-contains line ".scope") (string-contains line ".service"))) lines) #t))))
      :boolean))

;; Whether helpers leave Tuna's systemd scope or service, for CHOICE
;; ('always, 'never, or 'auto: when Tuna runs in one).
(def (helper-leaves-scope? (choice : :symbol)) => :boolean
  (case choice
    ((always) #t)
    ((never) #f)
    (else (in-systemd-unit?))))

;; The arguments of `setsid` that start PROGRAM (the program and its
;; arguments) detached, in a systemd scope of its own named UNIT when
;; UNIT is given.
(def (detached-command (program : :list) (unit :? :string)) => :list
  (append ["-f"]
          (if unit
            ["systemd-run" "--user" "--scope" "--quiet" "--collect" (string-append "--unit=" unit)]
            [])
          program))

;; Start PROGRAM detached (detached-command) with ENVIRONMENT ("NAME=value"
;; strings; #f for Tuna's own) and return once it is; raises when the
;; command to start it fails.
(def (launch-detached! (program : :list) (environment :? :list) (unit :? :string)) => :void
  (let* ((process (open-process [path: "setsid" arguments: (detached-command program unit)
                                 environment: environment
                                 stdin-redirection: #t stdout-redirection: #f stderr-redirection: #f]))
         (status (begin (close-output-port process) (process-status process 10 #f))))
    (close-port process)
    (unless (eqv? status 0)
      (error "Cannot start the helper" (car program) status))))

;; Wait up to SECONDS for the socket at PATH to appear: whether it did.
(def (wait-for-socket (path : :string) (seconds : :real)) => :boolean
  (let lp ((left seconds))
    (cond
     ((file-exists? path) #t)
     ((<= left 0) #f)
     (else (thread-sleep! 0.02) (lp (- left 0.02))))))

;;; Writing without waiting

;; A thread writing byte vectors to a device, in the order they were
;; sent, so the sender never waits on the device.
(defclass device-writer ((thread : :thread))
  final: #t)

(def (writer-thread (device : :t)) => :void
  (with-catch
   void
   (lambda ()
     (let lp ()
       (let (message (thread-receive))
         (when (u8vector? message)
           (device-write-all device message)
           (lp))))))
  (with-catch void (lambda () (shutdown-device device))))

;; A writer to DEVICE, its thread named NAME. Once closed, or once a
;; write fails, it ends both directions of DEVICE (shutdown-device), so
;; whoever reads DEVICE sees the end and closes it.
(def (new-device-writer (device : :t) (name : :symbol)) => device-writer
  (device-writer thread: (spawn/name name (lambda () (writer-thread device)))))

;; Write BYTES after what was sent before.
(def (device-writer-send! (w : device-writer) (bytes : :u8vector)) => :void
  (thread-send w.thread bytes))

;; End W after what was sent so far.
(def (device-writer-close! (w : device-writer)) => :void
  (thread-send w.thread 'close))
