;;; The Pi helper (ADR 18's pattern; docs/briefs/2026-10-pi-chat.md): one
;;; small program per chat, started by the pi plugin and living outside
;;; Tuna, so Pi goes on working while Tuna restarts. It runs
;;; `pi --mode rpc` on pipes in the chat's folder, Pi's standard error
;;; going to the helper's log, and serves one Tuna at a time on a private
;;; socket, in JSONL (jsonl.ss):
;;;   - to Tuna: a `helper_hello` line ({version, pid, piPid, piVersion},
;;;     or {error} when Pi cannot run, such as one older than 1.4.0),
;;;     then Pi's state and messages as Pi gave them to the helper's own
;;;     `get_state` and `get_messages` (ids "helper:state" and
;;;     "helper:messages"), then what those cannot hold (replay.ss), then
;;;     Pi's lines as Pi writes them; once Pi has ended, a `helper_exit`
;;;     line {status, stderr} with the end of what it wrote to its
;;;     standard error;
;;;   - from Tuna: Pi's commands, passed on as they are, and the
;;;     helper's own `helper_detach` (this Tuna leaves) and `helper_kill`
;;;     (end Pi and the helper).
;;; A second Tuna gets `helper_refused` while one is connected.
;;;
;;; Pi's output is always read, whether or not a Tuna listens; a Tuna
;;; that falls more than `queue-limit` bytes behind is dropped, and its
;;; next connection replays. With no Tuna, Pi settled and no dialog
;;; waiting, for --idle-exit seconds, the helper closes Pi's input, which
;;; ends Pi in order, and ends; the chat then comes back from Pi's session
;;; file. Once Pi ends, the helper ends after telling a Tuna, or after
;;; --idle-exit seconds with none.
;;;
;;;   tuna-pi-helper --socket PATH --directory DIR --log PATH
;;;     [--idle-exit SECONDS] [--model M] [--thinking LEVEL]
;;;     [--trust approve|default|no-approve] [--session FILE] -- PI ARG...
prelude: :gerbil/core

(import :std/encoding/json
        (only-in :std/os/signal SIGTERM SIGKILL kill)
        (only-in :std/os/signal-handler add-signal-handler!)
        :tuna/lib/unix
        ./jsonl
        ./replay)
(export main)

(def protocol-version 1)
;; Bytes queued to a Tuna beyond which it is dropped.
(def queue-limit (* 16 1024 1024))
;; Characters of Pi's standard error a Tuna is told when Pi ends.
(def stderr-tail-size 4000)
;; The oldest Pi the chat works with.
(def minimum-pi-version [1 4 0])

(defclass helper ((pi        :? :t)               ; Pi's process port, its input and output
                  (pi-pid    : :fixnum)
                  (pi-writer : :thread)            ; writes to Pi's input, in order
                  (listener  : :t)
                  (lock      : :mutex)             ; everything below
                  (client    :? :t)                ; the connected Tuna's device
                  (writer    :? :thread)           ; writes to CLIENT
                  (queued    : :fixnum)            ; bytes queued to CLIENT
                  (live?     : :boolean)           ; CLIENT had its snapshot
                  (snapshot-state :? :string)      ; the "helper:state" response, for CLIENT
                  (held      : :list)              ; responses to CLIENT before it was live, newest first
                  (replay    : replay-state)
                  (hello     : :string)
                  (status    :? :fixnum)           ; Pi's exit status, once it ended
                  (stderr    : :string)            ; and the end of its standard error
                  (alone-since : :real)            ; since when no Tuna is connected
                  (done      : :thread))
  final: #t)

(def (now) => :real (time->seconds (current-time)))

;;; Arguments

(defstruct options ((socket : :string) (directory : :string) (log : :string) (idle-exit : :real)
                    (model :? :string) (thinking :? :string) (trust : :string) (session :? :string)
                    (command : :list))
  final: #t)

(def usage "Usage: tuna-pi-helper --socket PATH --directory DIR --log PATH [--idle-exit SECONDS] [--model M] [--thinking LEVEL] [--trust approve|default|no-approve] [--session FILE] -- PI ARG...")

(def (parse-arguments (args : :list)) => options
  (let lp ((args args) (o (make-options "" "." "" 60 #f #f "approve" #f [])))
    (match args
      (["--" . command] (set! (options-command o) command) o)
      ([flag value . rest]
       (cond
        ((equal? flag "--socket") (set! (options-socket o) value))
        ((equal? flag "--directory") (set! (options-directory o) value))
        ((equal? flag "--log") (set! (options-log o) value))
        ((equal? flag "--idle-exit") (set! (options-idle-exit o) (or (string->number value) (error "Not a number" flag value))))
        ((equal? flag "--model") (set! (options-model o) value))
        ((equal? flag "--thinking") (set! (options-thinking o) value))
        ((equal? flag "--trust") (set! (options-trust o) value))
        ((equal? flag "--session") (set! (options-session o) value))
        (else (error "Unknown argument" flag)))
       (lp rest o))
      (else (error usage)))))

;; Pi's arguments after its command, as O asks.
(def (pi-arguments (o : options)) => :list
  (append ["--mode" "rpc"]
          (cond ((equal? (options-trust o) "approve") ["--approve"])
                ((equal? (options-trust o) "no-approve") ["--no-approve"])
                (else []))
          (let (m (options-model o)) (if m ["--model" m] []))
          (let (t (options-thinking o)) (if t ["--thinking" t] []))
          (let (s (options-session o)) (if s ["--session" s] []))))

;;; Pi's version

;; The first N.N.N in TEXT, as a list of numbers, or #f.
(def (version-numbers (text : :string)) => (Maybe :list)
  (let lp ((i 0))
    (and (fx< i (string-length text))
         (if (char-numeric? (string-ref text i))
           (let* ((end (let scan ((j i)) (if (and (fx< j (string-length text))
                                                  (or (char-numeric? (string-ref text j)) (char=? (string-ref text j) #\.)))
                                           (scan (fx1+ j)) j)))
                  (parts (map string->number (string-split (substring text i end) #\.))))
             (if (and (fx>= (length parts) 3) (andmap values parts))
               (take parts 3)
               (lp end)))
           (lp (fx1+ i))))))

(def (version<? (a : :list) (b : :list)) => :boolean
  (let lp ((a a) (b b))
    (cond ((null? a) #f)
          ((< (car a) (car b)) #t)
          ((> (car a) (car b)) #f)
          (else (lp (cdr a) (cdr b))))))

;; What COMMAND --version prints, run in DIRECTORY, and the problem with
;; it: (VERSION . #f), or (VERSION-OR-"" . WHY).
(def (check-pi-version (command : :list) (directory : :string)) => :pair
  (with-catch
   (lambda (e) (cons "" (string-append "Cannot run " (car command) ": " (error-text e))))
   (lambda ()
     (let* ((p (open-process [path: (car command) arguments: (append (cdr command) ["--version"])
                              directory: directory
                              stdin-redirection: #t stdout-redirection: #t stderr-redirection: #f]))
            (text (begin (close-output-port p) (read-line p #f)))
            (status (process-status p 30 #f)))
       (close-port p)
       (let* ((text (if (string? text) text ""))
              (numbers (version-numbers text))
              (version (if numbers (string-join (map number->string numbers) ".") (string-trim-both text))))
         (cond
          ((not (eqv? status 0)) (cons version (string-append (car command) " --version failed")))
          ((not numbers) (cons version (string-append "Cannot tell Pi's version from: " text)))
          ((version<? numbers minimum-pi-version)
           (cons version (string-append "Pi " version " is too old; Tuna's chat needs Pi 1.4.0 or newer")))
          (else (cons version #f))))))))

(def (error-text (e : :t)) => :string
  (if (error-object? e)
    (let (message (error-object-message e))
      (if (string? message) message "error"))
    "error"))

(def (string-trim-both (s : :string)) => :string
  (let* ((size (string-length s))
         (start (let lp ((i 0)) (if (and (fx< i size) (char-whitespace? (string-ref s i))) (lp (fx1+ i)) i)))
         (end (let lp ((i size)) (if (and (fx> i start) (char-whitespace? (string-ref s (fx1- i)))) (lp (fx1- i)) i))))
    (substring s start end)))

;;; The connected Tuna

(def (line-bytes (line : :string)) => :u8vector
  (string->utf8 (string-append line "\n")))

;; Queue LINE for the connected Tuna; drop a Tuna too far behind. Hold
;; H's lock.
(def (send-to-client! (h : helper) (line : :string)) => :void
  (when h.writer
    (let (bytes (line-bytes line))
      (set! h.queued (fx+ h.queued (u8vector-length bytes)))
      (if (fx> h.queued queue-limit)
        (drop-client! h)
        (thread-send h.writer bytes)))))

;; Forget the connected Tuna, ending its connection after what is queued.
;; Hold H's lock.
(def (drop-client! (h : helper)) => :void
  (when h.writer (thread-send h.writer 'close))
  (set! h.client #f)
  (set! h.writer #f)
  (set! h.live? #f)
  (set! h.snapshot-state #f)
  (set! h.held [])
  (set! h.queued 0)
  (set! h.alone-since (now)))

(def (client-writer-thread (h : helper) (device : :t)) => :void
  (with-catch
   (lambda (e) (do-with-lock h.lock (when (eq? h.client device) (drop-client! h))))
   (lambda ()
     (let lp ()
       (let (message (thread-receive))
         (when (u8vector? message)
           (device-write-all device message)
           (do-with-lock h.lock
             (when (eq? h.client device)
               (set! h.queued (fxmax 0 (fx- h.queued (u8vector-length message))))))
           (lp))))))
  (with-catch void (lambda () (shutdown-device device))))

;; Lines from the connected Tuna: Pi's commands go to Pi; the helper's own
;; are acted on.
(def (client-reader-thread (h : helper) (device : :t)) => :void
  (let ((reader (new-jsonl-reader))
        (buffer (make-u8vector 65536 0)))
    (with-catch
     void
     (lambda ()
       (let lp ()
         (let (n (device-read-some device buffer))
           (when (fx> n 0)
             (for-each (cut client-line! h device <>) (jsonl-reader-feed! reader buffer 0 n))
             (lp))))))
    (do-with-lock h.lock (when (eq? h.client device) (drop-client! h)))
    (with-catch void (lambda () (close-device device)))))

(def (client-line! (h : helper) (device : :t) (line : :string)) => :void
  (let* ((record (parse-json-line line))
         (type (json-field record "type")))
    (cond
     ((equal? type "helper_detach") (do-with-lock h.lock (when (eq? h.client device) (drop-client! h))))
     ((equal? type "helper_kill") (thread-send h.done 'kill))
     (else
      (do-with-lock h.lock (when record (replay-note-tuna-record! h.replay record)))
      (thread-send h.pi-writer (line-bytes line))))))

;; A Tuna connected: say hello, then ask Pi for its state and messages,
;; which make its snapshot; or, Pi having ended (or never started), say
;; so. Hold H's lock.
(def (welcome! (h : helper) (device : :t)) => :void
  (set! h.client device)
  (set! h.writer (spawn/name 'pi-client-writer (lambda () (client-writer-thread h device))))
  (spawn/name 'pi-client-reader (lambda () (client-reader-thread h device)))
  (send-to-client! h h.hello)
  (cond
   (h.status
    (send-exit! h)
    (thread-send h.done 'told))
   (h.pi
    (thread-send h.pi-writer (line-bytes "{\"id\":\"helper:state\",\"type\":\"get_state\"}"))
    (thread-send h.pi-writer (line-bytes "{\"id\":\"helper:messages\",\"type\":\"get_messages\"}")))
   (else (void))))

(def (send-exit! (h : helper)) => :void
  (send-to-client! h (json->string (hash ("type" "helper_exit") ("status" h.status) ("stderr" h.stderr)))))

(def (acceptor-thread (h : helper)) => :void
  (let lp ()
    (let (device (with-catch (lambda (e) #f) (lambda () (unix-accept h.listener))))
      (when device
        (do-with-lock h.lock
          (if h.client
            (with-catch void
                        (lambda ()
                          (device-write-all device (line-bytes "{\"type\":\"helper_refused\",\"reason\":\"busy\"}"))
                          (close-device device)))
            (welcome! h device)))
        (lp)))))

;;; Pi

(def (pi-writer-thread (h : helper)) => :void
  (let lp ()
    (let (message (thread-receive))
      (cond
       ((u8vector? message)
        (with-catch void (lambda ()
                           (write-subu8vector message 0 (u8vector-length message) h.pi)
                           (force-output h.pi)))
        (lp))
       ;; Closing Pi's input ends it in order.
       ((eq? message 'close) (with-catch void (lambda () (close-output-port h.pi))))
       (else (lp))))))

;; A line Pi wrote: kept for replay, and sent to the Tuna once it is live;
;; the snapshot's two responses are the helper's own. Hold H's lock.
(def (pi-line! (h : helper) (line : :string)) => :void
  (let* ((record (parse-json-line line))
         (id (json-field record "id"))
         (response? (equal? (json-field record "type") "response")))
    (cond
     ((and response? (equal? id "helper:state"))
      (when (and h.client (not h.live?)) (set! h.snapshot-state line)))
     ((and response? (equal? id "helper:messages"))
      (when (and h.client (not h.live?))
        (let (state h.snapshot-state)
          (when state (send-to-client! h state)))
        (send-to-client! h line)
        (for-each (cut send-to-client! h <>) (replay-lines h.replay (now)))
        (for-each (cut send-to-client! h <>) (reverse h.held))
        (set! h.held [])
        (set! h.live? #t)))
     (else
      (when record (replay-note-pi-line! h.replay line record (now)))
      (cond
       (h.live? (send-to-client! h line))
       ;; A response to the Tuna that is connecting: after its snapshot.
       ((and h.client response? id) (set! h.held (cons line h.held)))
       (else (void)))))))

;; Read Pi's output, always, until it ends; then keep its exit status and
;; the end of its standard error, and tell the Tuna.
(def (pi-reader-thread (h : helper) (log : :string) (log-start : :integer)) => :void
  (let ((reader (new-jsonl-reader))
        (buffer (make-u8vector 65536 0)))
    (let lp ()
      (let (n (with-catch (lambda (e) 0) (lambda () (read-subu8vector buffer 0 (u8vector-length buffer) h.pi 1))))
        (when (fx> n 0)
          (let (lines (jsonl-reader-feed! reader buffer 0 n))
            (do-with-lock h.lock (for-each (cut pi-line! h <>) lines)))
          (lp))))
    (let* ((raw (with-catch (lambda (e) 255) (lambda () (process-status h.pi))))
           (status (if (fx= (fxand raw 127) 0) (fxarithmetic-shift-right raw 8) (fx+ 128 (fxand raw 127))))
           (tail (stderr-tail log log-start)))
      (with-catch void (lambda () (close-port h.pi)))
      (do-with-lock h.lock
        (set! h.status status)
        (set! h.stderr tail)
        (when h.client (send-exit! h)))
      (thread-send h.done 'ended))))

;; The last stderr-tail-size characters LOG gained after its first
;; START bytes: what Pi wrote to its standard error.
(def (stderr-tail (log : :string) (start : :integer)) => :string
  (with-catch
   (lambda (e) "")
   (lambda ()
     (if (string-empty? log)
       ""
       (let* ((size (file-info-size (file-info log)))
              (from (max start (- size (* 4 stderr-tail-size))))
              (bytes (call-with-input-file log
                       (lambda (port)
                         (input-port-byte-position port from)
                         (let (b (make-u8vector (max 0 (- size from)) 0))
                           (read-subu8vector b 0 (u8vector-length b) port)
                           b))))
              (text (utf8->string bytes)))
         (if (fx> (string-length text) stderr-tail-size)
           (substring text (fx- (string-length text) stderr-tail-size) (string-length text))
           text))))))

;;; Idle exit

(def (idle-thread (h : helper) (seconds : :real)) => :void
  (let lp ()
    (thread-sleep! (min 1.0 (max 0.05 (/ seconds 4))))
    (let (idle? (do-with-lock h.lock
                  (and (not h.client)
                       (>= (- (now) h.alone-since) seconds)
                       (or h.status
                           (and (replay-settled? h.replay) (fx= 0 (replay-dialog-count h.replay (now))))))))
      (if idle?
        (thread-send h.done 'idle)
        (lp)))))

;; End Pi: closing its input ends it in order; one that lingers gets
;; SIGTERM after 5 s, then SIGKILL after 3 more.
(def (end-pi! (h : helper)) => :void
  (thread-send h.pi-writer 'close)
  (for-each (lambda ((signal : :fixnum) (seconds : :real))
              (let wait ((left seconds))
                (cond
                 ((do-with-lock h.lock h.status) (void))
                 ((<= left 0) (with-catch void (lambda () (kill h.pi-pid signal))))
                 (else (thread-sleep! 0.05) (wait (- left 0.05))))))
            [SIGTERM SIGKILL] [5.0 3.0]))

;;; Main

(def (main . args)
  (let* ((o (parse-arguments args))
         (command (options-command o)))
    (when (or (string-empty? (options-socket o)) (null? command))
      (error usage))
    (start-session)
    (redirect-standard-ports (options-log o))
    (let* ((directory (options-directory o))
           (checked (check-pi-version command directory))
           (problem (cdr checked))
           (log (options-log o))
           (log-start (with-catch (lambda (e) 0) (lambda () (file-info-size (file-info log)))))
           (pi (and (not problem)
                    (with-catch (lambda (e) (set! problem (string-append "Cannot start Pi: " (error-text e))) #f)
                                (lambda ()
                                  (open-process [path: (car command)
                                                 arguments: (append (cdr command) (pi-arguments o))
                                                 directory: directory
                                                 stdin-redirection: #t stdout-redirection: #t
                                                 stderr-redirection: #f])))))
           (hello (json->string
                   (let (fields (hash ("type" "helper_hello") ("version" protocol-version)
                                      ("pid" (current-process-id))
                                      ("piPid" (if pi (process-pid pi) 0))
                                      ("piVersion" (car checked))))
                     (when problem (hash-put! fields "error" problem))
                     fields)))
           (listener (unix-listen (options-socket o)))
           (h (helper pi: pi pi-pid: (if pi (process-pid pi) 0) pi-writer: (current-thread)
                      listener: listener lock: (make-mutex 'pi-helper)
                      client: #f writer: #f queued: 0 live?: #f snapshot-state: #f held: []
                      replay: (new-replay-state) hello: hello status: #f stderr: ""
                      alone-since: (now) done: (current-thread))))
      (if pi
        (begin
          (set! (helper-pi-writer h) (spawn/name 'pi-writer (lambda () (pi-writer-thread h))))
          (spawn/name 'pi-reader (lambda () (pi-reader-thread h log log-start))))
        ;; Pi never started: the next Tuna hears why, as if it had ended.
        (begin
          (set! (helper-status h) 127)
          (set! (helper-stderr h) problem)))
      (spawn/name 'pi-acceptor (lambda () (acceptor-thread h)))
      (spawn/name 'pi-idle (lambda () (idle-thread h (options-idle-exit o))))
      (add-signal-handler! SIGTERM (lambda () (thread-send (helper-done h) 'kill)))
      (let (why
            (let lp ()
              (let (message (thread-receive))
                (case message
                  ;; Pi ended: end once a Tuna was told (once that is
                  ;; written), or after --idle-exit seconds without one.
                  ((ended) (if (do-with-lock (helper-lock h) (helper-client h)) 'ended (lp)))
                  ((told) 'ended)
                  ((idle kill) (when pi (end-pi! h)) message)
                  (else (lp))))))
        ;; Let the last lines reach Tuna before closing.
        (let (writer (do-with-lock (helper-lock h) (let (w (helper-writer h)) (drop-client! h) w)))
          (when writer (with-catch void (lambda () (thread-join! writer 2.0)))))
        (with-catch void (lambda () (delete-file (options-socket o))))
        ;; The log is kept only when Pi failed on its own: it says why.
        (unless (or (string-empty? log) (and (eq? why 'ended) (not (eqv? (helper-status h) 0))))
          (with-catch void (lambda () (delete-file log))))
        (exit 0)))))
