;;; The terminal helper (ADR 18): one small program per terminal, started
;;; by the terminal plugin and living outside Tuna, so its program survives
;;; Tuna restarting. It starts the program on a pseudo-terminal, keeps its
;;; own libghostty-vt terminal fed with every byte the program writes, and
;;; serves one Tuna at a time on a private socket (protocol.ss): a snapshot
;;; of its terminal, then the live output; keys and sizes come back. It
;;; answers the program's queries (cursor position, device attributes,
;;; and colours: Tuna tells it the theme's, `colors`) itself, since it is
;;; the one always there. It ends when its program has
;;; ended and a Tuna has seen that, or when Tuna asks it to kill the
;;; program.
;;;
;;; As Tuna's `settings` say, it saves its screen (saved-screen.ss) every
;;; so often while it changes, and when it is asked to end (SIGTERM, as a
;;; shutdown sends), so the terminal can come back after a reboot; it
;;; removes the file when its terminal ends or is killed on purpose. It
;;; compresses its scrollback once its program has been quiet a while.
;;;
;;;   tuna-terminal-helper --socket PATH [--columns N] [--rows N]
;;;     [--scrollback BYTES] [--directory DIR] [--log PATH]
;;;     [--restore SNAPSHOT] -- PROGRAM ARG...
;;;
;;; With --restore, its terminal starts as that snapshot file holds it (a
;;; terminal brought back after its helper was gone), and the file is
;;; removed. The program gets the helper's own environment. The helper
;;; starts a session of its own and drops its standard ports, so nothing
;;; ties it to whatever started it.
prelude: :gerbil/core

(import (rename-in :gerbil-libghostty/ghostty (terminal? ghostty-terminal?))
        (only-in :std/os/signal SIGTERM)
        (only-in :std/os/signal-handler add-signal-handler!)
        ./io
        ./protocol
        ./saved-screen)
(export main)

;; Bytes read from the pseudo-terminal at a time.
(def read-size 65536)
;; Output queued for a slow Tuna above which the program is not read, so
;; it waits, as it would for a slow terminal.
(def queue-limit (* 4 1024 1024))
;; Seconds between checks of whether the program ended.
(def watch-interval 0.1)
;; Seconds between checks of whether to save or compress.
(def tick-interval 1.0)
;; Seconds after SIGHUP before a killed program gets SIGKILL.
(def kill-grace 1.0)
(def sighup 1)
(def sigkill 9)

(defclass helper ((term      : terminal)         ; libghostty terminal
                  (pty       : :t)               ; the master, as a device
                  (child     : :fixnum)          ; the program's pid
                  (listener  : :t)               ; device
                  (socket    : :string)
                  (lock      : :mutex)           ; TERM, CLIENT and what is queued to it
                  (client    :? :t)              ; device of the connected Tuna
                  (writer    :? :thread)         ; writes to CLIENT
                  (live?     : :boolean)         ; CLIENT has its snapshot
                  (queued    : :fixnum)          ; bytes queued to CLIENT
                  (pty-writer : :thread)
                  (replies   : :list)            ; the terminal's answers, newest first
                  (columns   : :fixnum)
                  (rows      : :fixnum)
                  (cell-width : :fixnum)
                  (cell-height : :fixnum)
                  (scheme    :? :symbol)         ; light or dark, from Tuna's colours
                  (status    :? :fixnum)         ; the program's, once it ended
                  (killed?   : :boolean)
                  (wanted    :? helper-settings) ; what Tuna's settings ask: saving, compressing
                  (changed?  : :boolean)         ; the screen changed since it was saved
                  (saved-at  : :real)            ; when it was last saved
                  (output-at : :real)            ; when the program last wrote
                  (compressed? : :boolean)       ; nothing written since compressing
                  (done      : :thread))         ; main, waiting to be told to end
  final: #t)

;;; Arguments

(defstruct options ((socket : :string) (columns : :fixnum) (rows : :fixnum) (scrollback : :integer)
                    (directory : :string) (log : :string) (restore : :string) (program : :list))
  final: #t)

(def (parse-arguments (args : :list)) => options
  (let lp ((args args) (o (make-options "" 80 24 (* 5 1024 1024) "" "" "" [])))
    (match args
      (["--" . program] (set! (options-program o) program) o)
      ([flag value . rest]
       (let (number (lambda () (or (string->number value) (error "Not a number" flag value))))
         (cond
          ((equal? flag "--socket") (set! (options-socket o) value))
          ((equal? flag "--columns") (set! (options-columns o) (number)))
          ((equal? flag "--rows") (set! (options-rows o) (number)))
          ((equal? flag "--scrollback") (set! (options-scrollback o) (number)))
          ((equal? flag "--directory") (set! (options-directory o) value))
          ((equal? flag "--log") (set! (options-log o) value))
          ((equal? flag "--restore") (set! (options-restore o) value))
          (else (error "Unknown argument" flag)))
         (lp rest o)))
      (else (error "Usage: tuna-terminal-helper --socket PATH ... -- PROGRAM ARG...")))))

;; This process's environment, as "NAME=value" strings.
(def (environment-strings) => :list
  (map (lambda ((pair : :pair)) (string-append (car pair) "=" (cdr pair)))
       (get-environment-variables)))

;; PROGRAM as an absolute path: itself when it names a folder, else the
;; first executable file of that name on PATH.
(def (resolve-program (program : :string)) => :string
  (if (string-index program #\/)
    program
    (or (find (lambda ((path : :string)) (file-executable? path))
              (map (lambda ((folder : :string)) (path-expand program folder))
                   (string-split (or (getenv "PATH" #f) "/usr/bin:/bin") #\:)))
        (error "No such program on PATH" program))))

(def (file-executable? (path : :string)) => :boolean
  (and (file-exists? path)
       (eq? (file-info-type (file-info path)) 'regular)
       (fx> (fxand (file-info-mode (file-info path)) #o111) 0)))

;;; The client

;; Queue BYTES for the connected Tuna. Hold H's lock.
(def (send-to-client! (h : helper) (bytes : :u8vector)) => :void
  (when h.writer
    (set! h.queued (fx+ h.queued (u8vector-length bytes)))
    (thread-send h.writer bytes)))

;; Forget the connected Tuna, closing its connection after what is queued.
;; Hold H's lock.
(def (drop-client! (h : helper)) => :void
  (when h.writer (thread-send h.writer 'close))
  (set! h.client #f)
  (set! h.writer #f)
  (set! h.live? #f)
  (set! h.queued 0))

;; Write what is queued to DEVICE, in order; after 'close, end the
;; connection, which its reader sees and closes.
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

;; Answer a Tuna's hello: our hello, the snapshot, and the exit if the
;; program has ended. Hold H's lock.
(def (welcome! (h : helper)) => :void
  (send-to-client! h (frame-bytes 'hello (helper-hello-payload
                                          (make-helper-hello protocol-version (current-process-id) h.child
                                                             h.columns h.rows))))
  (send-to-client! h (frame-bytes 'snapshot (terminal->snapshot-bytes h.term)))
  (set! h.live? #t)
  (when h.status
    (send-to-client! h (frame-bytes 'exit (exit-payload h.status)))))

(def (client-reader-thread (h : helper) (device : :t)) => :void
  (let ((reader (new-frame-reader))
        (buffer (make-u8vector 65536 0)))
    (with-catch
     void
     (lambda ()
       (let lp ()
         (let (n (device-read-some device buffer))
           (when (fx> n 0)
             (for-each (cut handle-frame! h device <>) (frame-reader-feed! reader buffer 0 n))
             (lp))))))
    (do-with-lock h.lock (when (eq? h.client device) (drop-client! h)))
    (with-catch void (lambda () (close-device device)))))

(def (handle-frame! (h : helper) (device : :t) (f : frame)) => :void
  (let (payload (frame-payload f))
    (case (frame-type f)
      ((hello)
       (do-with-lock h.lock
         (when (eq? h.client device)
           (if (fx= (parse-hello payload) protocol-version)
             (welcome! h)
             (begin
               (send-to-client! h (frame-bytes 'refused (string->utf8 "protocol version")))
               (drop-client! h))))))
      ((input) (thread-send h.pty-writer payload))
      ((resize)
       (let (r (parse-resize payload))
         (when r
           (resize! h (resize-request-columns r) (resize-request-rows r)
                    (resize-request-cell-width r) (resize-request-cell-height r)))))
      ((focus)
       (let (mode (cdr (assq 'focus-event (terminal-modes))))
         (when (do-with-lock h.lock (terminal-mode-enabled? h.term mode))
           (thread-send h.pty-writer (focus-encode (if (and (fx> (u8vector-length payload) 0)
                                                            (fx= (u8vector-ref payload 0) 1))
                                                     'gained 'lost))))))
      ((colors) (let (c (parse-colors payload)) (when c (set-colors! h c))))
      ((settings) (let (s (parse-helper-settings payload)) (when s (adopt-settings! h s))))
      ((kill) (forget-saved-screen! h) (kill-program! h))
      ;; The terminal ended and Tuna showed it: nothing to bring back.
      ((exit-ack) (when h.status (forget-saved-screen! h) (thread-send h.done 'end)))
      (else (void)))))

;; Resize the terminal, and tell the connected Tuna where in the output
;; that happened, so its mirror resizes at the same point and never
;; parses output written for one size at another.
(def (resize! (h : helper) (columns : :fixnum) (rows : :fixnum) (width : :fixnum) (height : :fixnum))
  => :void
  (do-with-lock h.lock
    (set! h.columns columns)
    (set! h.rows rows)
    (set! h.cell-width width)
    (set! h.cell-height height)
    (terminal-resize! h.term columns rows cell-width-px: width cell-height-px: height)
    (when h.live?
      (send-to-client! h (frame-bytes 'resized (resize-payload (make-resize-request columns rows width height))))))
  (pty-resize (device-fd h.pty) columns rows (fx* columns width) (fx* rows height))
  (void))

(def (acceptor-thread (h : helper)) => :void
  (let lp ()
    (let (device (with-catch (lambda (e) #f) (lambda () (unix-accept h.listener))))
      (when device
        (do-with-lock h.lock
          (if h.client
            ;; One Tuna at a time.
            (with-catch void
                        (lambda ()
                          (device-write-all device (frame-bytes 'refused (string->utf8 "busy")))
                          (close-device device)))
            (begin
              (set! h.client device)
              (set! h.writer (spawn/name 'terminal-client-writer (lambda () (client-writer-thread h device))))
              (spawn/name 'terminal-client-reader (lambda () (client-reader-thread h device))))))
        (lp)))))

;;; Colours

(def (rgb-color (n :? :fixnum)) => :t
  (and n (color-rgb (fxand (fxarithmetic-shift-right n 16) 255) (fxand (fxarithmetic-shift-right n 8) 255)
                    (fxand n 255))))

;; Make C the terminal's default colours, which it answers OSC 4, 10, 11
;; and 12 queries with, and its background's lightness the colour scheme
;; it reports (CSI ? 996 n); a program that asked to hear of changes
;; (mode 2031) hears of a new scheme.
(def (set-colors! (h : helper) (c : theme-colors)) => :void
  (let (report
        (do-with-lock h.lock
          (let ((term h.term)
                (background (rgb-color (theme-colors-background c)))
                (palette (theme-colors-palette c)))
            (terminal-set-default-foreground! term (rgb-color (theme-colors-foreground c)))
            (terminal-set-default-background! term background)
            (terminal-set-default-cursor-color! term (rgb-color (theme-colors-cursor c)))
            (terminal-set-default-palette!
             term
             (and (fx> (vector-length palette) 0)
                  (let (full (color-default-palette))
                    (let lp ((i 0))
                      (when (fx< i (fxmin 256 (vector-length palette)))
                        (vector-set! full i (rgb-color (vector-ref palette i)))
                        (lp (fx1+ i))))
                    full)))
            (let ((scheme (and background (if (< (color-perceived-luminance background) 0.5) 'dark 'light)))
                  (old h.scheme))
              (set! h.scheme scheme)
              (and scheme (not (eq? scheme old))
                   (terminal-mode-enabled? term (cdr (assq 'color-scheme-report (terminal-modes))))
                   (color-scheme-report-encode scheme))))))
    (when report (thread-send h.pty-writer report))))

;;; Saving and compressing

(def (now) => :real
  (time->seconds (current-time)))

;; Take Tuna's settings S; saving to a new file, or no longer saving,
;; removes the old one, and the screen is saved at once (Tuna sends them
;; on connecting and when it stops).
(def (adopt-settings! (h : helper) (s : helper-settings)) => :void
  (let (old (do-with-lock h.lock (let (old h.wanted) (set! h.wanted s) old)))
    (when (and old (not (equal? (helper-settings-save-path old) (helper-settings-save-path s)))
               (not (string-empty? (helper-settings-save-path old))))
      (delete-saved-screen! (helper-settings-save-path old)))
    (save-screen! h #t)))

;; Write the terminal's snapshot, trimmed to the rows of scrollback the
;; settings keep, to the file they name: when ALWAYS?, or when the screen
;; changed since the last save. Failing to save is not fatal.
(def (save-screen! (h : helper) (always? : :boolean)) => :void
  (let* ((s h.wanted)
         (path (and s (helper-settings-save-path s)))
         (snapshot (and path (not (string-empty? path))
                        (do-with-lock h.lock
                          (and (or always? h.changed?)
                               (begin (set! h.changed? #f)
                                      (set! h.saved-at (now))
                                      (terminal->snapshot-bytes h.term)))))))
    (when snapshot
      (with-catch (lambda (e) (set! h.changed? #t))
                  (lambda ()
                    (write-saved-screen! path (trimmed-snapshot snapshot (helper-settings-saved-rows s))))))))

;; Remove the saved screen and save no more: the terminal is gone on
;; purpose.
(def (forget-saved-screen! (h : helper)) => :void
  (let (s (do-with-lock h.lock (let (s h.wanted) (set! h.wanted #f) s)))
    (when s
      (let (path (helper-settings-save-path s))
        (unless (string-empty? path) (delete-saved-screen! path))))))

;; Now and then: save the screen once its interval has passed since the
;; last save and it changed, and compress the scrollback once the program
;; has been quiet for the settings' delay.
(def (saver-thread (h : helper)) => :void
  (let lp ()
    (thread-sleep! tick-interval)
    (let ((s h.wanted)
          (t (now)))
      (when s
        (when (and h.changed? (fx> (helper-settings-save-interval s) 0)
                   (>= (- t h.saved-at) (helper-settings-save-interval s)))
          (save-screen! h #f))
        (let (delay (helper-settings-compress-after s))
          (when (and delay (not h.compressed?) (>= (- t h.output-at) delay))
            (do-with-lock h.lock
              (terminal-compress! h.term mode: 'full)
              (set! h.compressed? #t))))))
    (lp)))

;;; The program

(def (pty-writer-thread (h : helper)) => :void
  (let lp ()
    (let (bytes (thread-receive))
      (when (u8vector? bytes)
        (with-catch void (lambda () (device-write-all h.pty bytes)))
        (lp)))))

;; Feed what the program wrote to the terminal and to the connected Tuna,
;; until the terminal has no writer left.
(def (pty-reader-thread (h : helper)) => :void
  (let (buffer (make-u8vector read-size 0))
    (let lp ()
      (let (n (with-catch (lambda (e) 0) (lambda () (device-read-some h.pty buffer))))
        (when (fx> n 0)
          (let (replies
                (do-with-lock h.lock
                  (set! h.replies [])
                  (terminal-write! h.term buffer start: 0 end: n)
                  (set! h.changed? #t)
                  (set! h.compressed? #f)
                  (set! h.output-at (now))
                  (when h.live?
                    (send-to-client! h (frame-bytes 'output (subu8vector buffer 0 n))))
                  (reverse h.replies)))
            (for-each (cut thread-send h.pty-writer <>) replies))
          ;; A Tuna that cannot keep up holds the program back.
          (let wait ()
            (when (do-with-lock h.lock (fx> h.queued queue-limit))
              (thread-sleep! 0.01)
              (wait)))
          (lp))))))

;; Wait for the program to end, give its last output a moment to arrive,
;; and tell the connected Tuna; end at once if it was killed and no Tuna is
;; there to see it.
(def (watcher-thread (h : helper) (reader : :thread)) => :void
  (let lp ()
    (let (status (child-status h.child))
      (if status
        (begin
          (with-catch void (lambda () (thread-join! reader 0.5)))
          (do-with-lock h.lock
            (set! h.status status)
            (when h.live?
              (send-to-client! h (frame-bytes 'exit (exit-payload status)))))
          (when h.killed?
            (thread-send h.done 'end)))
        (begin
          (thread-sleep! watch-interval)
          (lp))))))

;; Hang up the program's process group, then kill it if it lingers.
(def (kill-program! (h : helper)) => :void
  (unless h.killed?
    (set! h.killed? #t)
    (if h.status
      (thread-send h.done 'end)
      (begin
        (signal-group h.child sighup)
        (spawn/name 'terminal-kill
                    (lambda ()
                      (thread-sleep! kill-grace)
                      (unless h.status (signal-group h.child sigkill))))))))

;;; Main

;; The terminal of COLUMNS x ROWS a helper starts with: the one the
;; snapshot file RESTORE holds ("" for none), which is then removed, else
;; a new one.
(def (restored-or-new-terminal (restore : :string) (columns : :fixnum) (rows : :fixnum)) => terminal
  (let* ((bytes (and (not (string-empty? restore)) (read-saved-screen restore)))
         (term (and bytes (with-catch (lambda (e) #f) (lambda () (snapshot-bytes->terminal bytes))))))
    (unless (string-empty? restore) (delete-saved-screen! restore))
    (if term
      (begin
        (terminal-set-continuation-max-bytes! term (* 1024 1024))
        (terminal-resize! term columns rows)
        term)
      (make-terminal columns rows continuation-max-bytes: (* 1024 1024)))))

(def (main . args)
  (let* ((o (parse-arguments args))
         (program (options-program o)))
    (when (or (string-empty? (options-socket o)) (null? program))
      (error "Usage: tuna-terminal-helper --socket PATH ... -- PROGRAM ARG..."))
    (start-session)
    (redirect-standard-ports (options-log o))
    (default-child-signal)
    (let* ((columns (options-columns o))
           (rows (options-rows o))
           (term (restored-or-new-terminal (options-restore o) columns rows))
           (listener (unix-listen (options-socket o)))
           (spawned (spawn-on-pty (resolve-program (car program)) program (environment-strings)
                                  (options-directory o) columns rows))
           (h (helper term: term pty: (fd-device (car spawned) "pty") child: (cdr spawned)
                      listener: listener socket: (options-socket o) lock: (make-mutex 'terminal-helper)
                      client: #f writer: #f live?: #f queued: 0 pty-writer: (current-thread)
                      replies: [] columns: columns rows: rows cell-width: 0 cell-height: 0
                      scheme: #f status: #f killed?: #f wanted: #f changed?: #t saved-at: 0 output-at: (now)
                      compressed?: #f done: (current-thread))))
      (terminal-set-scrollback-max-bytes! term (options-scrollback o))
      (terminal-set-pty-write-handler! term (lambda (bytes) (set! (helper-replies h) (cons bytes (helper-replies h)))))
      (terminal-set-color-scheme-handler! term (lambda () (helper-scheme h)))
      ;; With a program status handler set, libghostty answers a program's
      ;; OSC 7501 query (Claude Code asks before it reports); Tuna's mirror
      ;; keeps the records.
      (terminal-set-program-status-handler! term void)
      (terminal-set-size-handler! term (lambda ()
                                         (terminal-size (helper-rows h) (helper-columns h)
                                                        (helper-cell-width h) (helper-cell-height h))))
      (set! (helper-pty-writer h) (spawn/name 'terminal-pty-writer (lambda () (pty-writer-thread h))))
      (let (reader (spawn/name 'terminal-pty-reader (lambda () (pty-reader-thread h))))
        (spawn/name 'terminal-watcher (lambda () (watcher-thread h reader))))
      (spawn/name 'terminal-acceptor (lambda () (acceptor-thread h)))
      (spawn/name 'terminal-saver (lambda () (saver-thread h)))
      ;; Asked to end (a shutdown, or kill): save the screen first, so the
      ;; terminal comes back after the reboot.
      (add-signal-handler! SIGTERM (lambda () (thread-send (helper-done h) 'terminate)))
      (let lp ()
        (case (thread-receive)
          ((end) (void))
          ((terminate) (save-screen! h #t))
          (else (lp))))
      ;; Let the last frames reach Tuna before closing.
      (let (writer (do-with-lock (helper-lock h) (let (w (helper-writer h)) (drop-client! h) w)))
        (when writer (with-catch void (lambda () (thread-join! writer 2.0)))))
      (with-catch void (lambda () (delete-file (options-socket o))))
      ;; A log with nothing in it says nothing.
      (let (log (options-log o))
        (with-catch void (lambda ()
                           (when (and (not (string-empty? log)) (zero? (file-info-size (file-info log))))
                             (delete-file log)))))
      (exit 0))))
