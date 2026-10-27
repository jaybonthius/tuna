#lang :tuna/prelude
;;; Terminals (ADR 18; agents/plans/terminal.md, stage 2), after ghostel.
;;; `M-x terminal` shows a shell in a buffer. The shell runs on a
;;; pseudo-terminal held by a helper process (helper.ss) outside Tuna, so it
;;; survives Tuna restarting, crashing, or this plugin being swapped or
;;; reloaded: the plugin keeps the list of helpers in its session slot and
;;; reconnects.
;;;
;;; Each terminal keeps a mirror: a libghostty-vt terminal restored from
;;; the helper's snapshot and fed the same bytes the helper's is, by a job
;;; that reads the helper's socket and posts what arrives; parsing runs in
;;; the job's apply, on the editor thread. Drawing reads only the mirror:
;;; after output, the rows that changed are copied into row nodes
;;; (screen.ss), at most every `terminal-timer-delay`, at once after a key
;;; (`terminal-immediate-redraw-interval`) or after a quiet spell, as
;;; ghostel draws. A view showing a terminal at its bottom follows its
;;; output; one scrolled up stays put. The alternate screen (vim, htop) is
;;; a grid of the screen's rows without scrollback.
;;;
;;; Keys: the terminal node's keymap is semi-char mode's, which sends every
;;; key to the program but `terminal-keymap-exceptions` (C-c, C-x, M-x, ...)
;;; and the C-c bindings, or char mode's (C-c M-d), which sends every key
;;; but M-RET, which goes back. C-q sends the next key, whatever it is. Keys
;;; go through libghostty's key encoder, so the program gets what it asked
;;; for (application cursor keys, the Kitty keyboard protocol).
;;;
;;; Each terminal is as big as the smallest view showing it, in cells, as
;;; Emacs sizes a process's window; the plugin's page script measures the
;;; views (web/terminal.js). A resize asks the helper for a fresh snapshot,
;;; so the mirror never parses output written for another size.
;;;
;;; The program's title (OSC 0/2), folder (OSC 7, the buffer's
;;; default-directory) and bell run the contract's hooks; when it ends the
;;; buffer goes (`terminal-kill-buffer-on-exit`), and killing a buffer whose
;;; program is busy asks first (`terminal-query-before-killing`).

(import (only-in :gerbil/runtime/hash HashTable)
        (only-in :std/encoding/json string->json current-json-read-options JSONReadOptions)
        :tuna/kernel
        :tuna/lib/jobs
        :tuna/lib/timers
        :tuna/lib/plugin-options
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/session/contract
        :tuna/plugins/clients/contract
        :tuna/plugins/stylesheets/contract
        :tuna/plugins/minibuffer/contract
        (only-in :tuna/plugins/editing/contract editing-service current-kill)
        (only-in :tuna/plugins/files/contract files-service file-system-service
                 default-directory buffer-default-directory)
        (only-in :tuna/plugins/web/contract page-service add-script context-add-page-address!)
        :tuna/plugins/terminal/contract
        (only-in :gerbil-libghostty/ghostty
                 snapshot-bytes->terminal terminal-write! terminal-close! terminal-resize!
                 terminal-set-scrollback-max-bytes! terminal-set-title-changed-handler!
                 terminal-set-pwd-changed-handler! terminal-set-bell-handler!
                 terminal-set-semantic-prompt-handler! semantic-prompt-event-kind
                 terminal-copy-changed-rows! terminal-copy-rows
                 row-changes-numbering row-changes-rows row-changes-frozen-start row-changes-frozen-end
                 row-changes-cursor row-changes-held?
                 row-numbering-screen row-numbering-generation row-numbering-first-row row-numbering-total-rows
                 row-cursor-row row-cursor-x row-cursor-visible? row-cursor-style row-cursor-blinking?
                 styled-row-number terminal-render-held? terminal-end-render-hold!
                 make-key-encoder key-encoder-encode paste-encode terminal-mode-enabled? terminal-modes)
        ./protocol
        ./io
        ./connection
        ./keys
        ./screen)
(export terminals
        terminal-shell
        terminal-term
        terminal-environment
        terminal-max-scrollback
        terminal-timer-delay
        terminal-adaptive-fps
        terminal-immediate-redraw-interval
        terminal-buffer-name
        terminal-buffer-name-function
        terminal-kill-buffer-on-exit
        terminal-query-before-killing
        terminal-initial-input-mode
        terminal-scroll-on-input
        terminal-ignore-cursor-change
        parse-directory-report
        terminal-process-environment)

;;; Settings (ghostel's defcustoms, with its defaults)

(defsetting terminal-shell #f
  "The program a terminal runs: #f for $SHELL (or /bin/sh), a path, or a list of a path and its arguments.")
(defsetting terminal-term "xterm-ghostty"
  "TERM for terminal programs: xterm-ghostty (this plugin's terminfo) or another, such as xterm-256color.")
(defsetting terminal-environment '()
  "Extra environment for terminal programs: \"NAME=value\" strings, which win over Tuna's own; a bare \"NAME\" unsets it.")
(defsetting terminal-max-scrollback (* 5 1024 1024)
  "Bytes of scrollback a terminal keeps, in its helper and its mirror (about 5,000 rows of 80 columns for 5 MB).")
(defsetting terminal-timer-delay 0.033
  "Seconds between redraws of a terminal under sustained output (about 30 per second).")
(defsetting terminal-adaptive-fps #t
  "Whether output after a quiet spell (100 ms) is drawn at once rather than after terminal-timer-delay.")
(defsetting terminal-immediate-redraw-interval 0.05
  "Seconds after a key within which a terminal's output is drawn at once, as its echo.")
(defsetting terminal-buffer-name "*terminal*"
  "The name of terminal buffers; later ones get <2>, <3>, ...")
(defsetting terminal-buffer-name-function #f
  "How a terminal's buffer is renamed as its program reports: #f never, 'title \"*terminal: TITLE*\", 'directory \"*terminal: FOLDER*\".")
(defsetting terminal-kill-buffer-on-exit #t
  "Whether a terminal's buffer is killed when its program ends.")
(defsetting terminal-query-before-killing 'auto
  "Whether killing a terminal's buffer asks first: #t while its program runs, #f never, 'auto while a command runs in it.")
(defsetting terminal-initial-input-mode 'semi-char
  "The input mode a new terminal starts in: 'semi-char or 'char.")
(defsetting terminal-scroll-on-input #t
  "Whether typing in a terminal scrolled up brings its views back to the bottom.")
(defsetting terminal-ignore-cursor-change #f
  "Whether a terminal ignores its program's cursor style and draws a block cursor.")

;;; State

(defclass (live-terminal terminal)
  ((socket       : :string)
   (link         :? connection)       ; to its helper, once connected
   (reader       :? job)
   (mirror       :? :t)                 ; libghostty terminal, from the helper's snapshot
   (helper-pid   : :fixnum)
   (child-pid    : :fixnum)
   (root         : node)
   (primary      : row-store)
   (alternate    : row-store)
   (screen       : :symbol)             ; which store the root shows
   (cursor-row   :? node)
   (columns      : :fixnum)
   (rows         : :fixnum)
   (cell-width   : :fixnum)
   (cell-height  : :fixnum)
   (effects      : :list)               ; from the mirror's handlers, newest first
   (input-mode   : :symbol)
   (initial-name : :string)
   (managed-name :? :string)
   (follow       : HashTable)           ; view -> number of the placement following output
   (last-input   : :real)
   (last-output  : :real)
   (timer        :? :t)            ; its redraw timer
   (sync-due?    : :boolean)
   (held-since   :? :real)
   (running?     : :boolean)            ; a command runs, by OSC 133
   (refusals     : :fixnum))
  final: #t)

(defclass terminals-state ((ctx       : context)
                           (terms     : HashTable)        ; id -> live-terminal
                           (by-buffer : HashTable)        ; buffer -> live-terminal
                           (semi-char : entry-table)
                           (char-map  : entry-table)
                           (quote-map : entry-table)
                           (jobs      : job-group)
                           (encoder   : :t)
                           (sizes     : HashTable)        ; client -> list of measured views
                           (quoting   : :list)            ; prompts waiting for a key, newest first
                           (poster    :? :procedure)
                           (focused   :? live-terminal)
                           (yank      : :fixnum)
                           (waiting   : :list)            ; terminals to connect once the loop runs
                           (stopping? : :boolean))
  final: #t)

(def (now) => :real
  (time->seconds (current-time)))

(def (service-there? (s : service)) => :boolean
  (and (service-provider s) #t))

;; On the baton: remember how to reach the editor loop from page posts.
(def (keep-poster! (self : terminals-state)) => :void
  (unless self.poster
    (with-catch void (lambda () (set! self.poster (result-poster))))))

;;; Starting programs

;; The program and arguments a new terminal runs.
(def (shell-command) => :list
  (let (shell (setting-value terminal-shell))
    (cond
     ((string? shell) [shell])
     ((and (pair? shell) (andmap string? shell)) (:- shell :list))
     (else [(or (getenv "SHELL" #f) "/bin/sh")]))))

;; Whether DIRECTORY holds a compiled xterm-ghostty entry.
(def (terminfo-usable? (directory : :string)) => :boolean
  (or (file-exists? (path-expand "x/xterm-ghostty" directory))
      (file-exists? (path-expand "78/xterm-ghostty" directory))))

;; The environment of a terminal's program, as ghostel builds it: the
;; terminal-environment setting first, then what says this is a Tuna
;; terminal and which TERM, then PWD, then BASE (Tuna's own); the first
;; entry for a name wins, and a bare "NAME" removes it.
(def (terminal-process-environment (extra : :list) (term : :string) (terminfo : :string)
                                   (directory : :string) (base : :list))
  => :list
  (let* ((term-entries
          (cond
           ((not (equal? term "xterm-ghostty")) [(string-append "TERM=" term) "COLORTERM=truecolor"])
           ((terminfo-usable? terminfo)
            ["TERM=xterm-ghostty" (string-append "TERMINFO=" terminfo) "TERM_PROGRAM=ghostty"
             "TERM_PROGRAM_VERSION=1.3.2" "COLORTERM=truecolor"])
           (else ["TERM=xterm-256color" "COLORTERM=truecolor"])))
         (entries (append extra ["INSIDE_TUNA=terminal"] term-entries
                          [(string-append "PWD=" directory)] base))
         (seen (make-hash-table)))
    (filter-map (lambda ((entry : :string))
                  (let* ((equals (string-index entry #\=))
                         (name (if equals (substring entry 0 equals) entry)))
                    (and (not (hash-get seen name))
                         (begin (hash-put! seen name #t) equals)
                         entry)))
                entries)))

(def (process-environment) => :list
  (map (lambda ((pair : :pair)) (string-append (car pair) "=" (cdr pair)))
       (get-environment-variables)))

;; A fresh helper id, unique across Tuna's runs.
(def (new-terminal-id) => :string
  (let (bytes (with-catch (lambda (e) (random-bytes))
                          (lambda () (call-with-input-file "/dev/urandom"
                                       (lambda (port) (let (b (make-u8vector 8 0))
                                                        (read-subu8vector b 0 8 port)
                                                        b))))))
    (:- (apply string-append (map (lambda (b) (string-append (if (< b 16) "0" "") (number->string b 16)))
                                  (u8vector->list bytes)))
        :string)))

(def (random-bytes) => :u8vector
  (let (b (make-u8vector 8 0))
    (let lp ((i 0))
      (when (fx< i 8)
        (u8vector-set! b i (random-integer 256))
        (lp (fx1+ i))))
    b))

;; The folder holding helpers' sockets: the socket-directory option, or
;; $XDG_RUNTIME_DIR/tuna/terminals (/tmp/tuna-UID/terminals without one),
;; made private.
(def (socket-directory) => :string
  (let ((option (:- (plugin-option terminals 'socket-directory) :string)))
    (if (not (string-empty? option))
      (begin (make-private-directory option) option)
      (let* ((runtime (getenv "XDG_RUNTIME_DIR" #f))
             (base (if (and runtime (not (string-empty? runtime)))
                     (path-expand "tuna" runtime)
                     (string-append "/tmp/tuna-" (number->string (current-user-id)))))
             (folder (path-expand "terminals" base)))
        (make-private-directory base)
        (make-private-directory folder)
        folder))))

;; Whether helpers leave Tuna's systemd scope (the leave-scope option).
(def (leave-scope?) => :boolean
  (case (plugin-option terminals 'leave-scope)
    ((always) #t)
    ((never) #f)
    (else (in-systemd-scope?))))

;;; Terminals and their buffers

(def (unique-buffer-name (name : :string)) => :string
  (if (not (get-buffer name))
    name
    (let lp ((n 2))
      (let (candidate (string-append name "<" (number->string n) ">"))
        (if (get-buffer candidate) (lp (fx1+ n)) candidate)))))

(def (new-live-terminal (self : terminals-state) (id : :string) (socket : :string) (name : :string)
                        (mode : :symbol) (columns : :fixnum) (rows : :fixnum))
  => live-terminal
  (let* ((root (new-node 'terminal attributes: [(cons 'id id) (cons 'screen 'primary)]
                         keymap: (if (eq? mode 'char) self.char-map self.semi-char)))
         (b (new-buffer name root))
         (term (live-terminal id: id shown: b title: "" directory: #f exit-status: #f
                              socket: socket link: #f reader: #f mirror: #f helper-pid: 0 child-pid: 0
                              root: root primary: (new-row-store) alternate: (new-row-store) screen: 'primary
                              cursor-row: #f columns: columns rows: rows cell-width: 0 cell-height: 0
                              effects: [] input-mode: mode initial-name: name managed-name: name
                              follow: (make-hash-table-eq) last-input: 0 last-output: 0 timer: #f
                              sync-due?: #f held-since: #f running?: #f refusals: 0)))
    (add-buffer! b)
    (hash-put! self.terms id term)
    (hash-put! self.by-buffer b term)
    (set! (live-terminal-timer term)
      (context-run-with-timer! self.ctx (setting-value terminal-timer-delay) #f
                               (lambda () (when (live-terminal-sync-due? term) (sync! self term)))
                               name: 'terminal-redraw))
    term))

;; The terminal the current buffer shows, or #f.
(def (current-terminal (self : terminals-state)) => (Maybe live-terminal)
  (hash-get self.by-buffer (current-buffer)))

(def (views-showing (term : live-terminal)) => :list
  (if (service-there? layout-service)
    (filter (lambda ((v : view)) (eq? (view-showing v) (terminal-buffer term))) (view-list))
    []))

;; Start the job reading TERM's helper: it starts the helper with LAUNCH
;; first when one is given, waits for its socket, connects, and posts the
;; connection, then every batch of frames, and ends with 'ended.
(def (start-reader! (self : terminals-state) (term : live-terminal) (launch :? helper-launch)) => :void
  (if (editor-loop-running?)
    (begin
      (keep-poster! self)
      (set! term.reader
        (job-group-start! self.jobs (terminal-id term)
                          input: (cons launch term.socket)
                          run: reader-run
                          apply: (lambda (result) (receive! self term result)))))
    ;; Restored at start, before the editor loop runs jobs: connect once
    ;; the first task runs.
    (set! self.waiting (cons term self.waiting))))

;; On the job's thread. Its input and posts are a helper launch, a
;; connection and frames: not editor state, so they may cross threads,
;; though they are not plain data.
(def (reader-run (input : :pair) (cancelled? : :procedure) (post! : :procedure)) => :t
  (let ((launch (car input))
        (socket (cdr input)))
    (with-catch
     (lambda (e) (cons 'failed (with-catch (lambda (_) "error") (lambda () (error-message e)))))
     (lambda ()
       (when launch (launch-helper! launch))
       (if (not (wait-for-socket socket (if launch 10 0.5)))
         'gone
         (let ((c (open-connection socket))
               (reader (new-frame-reader))
               (buffer (make-u8vector 65536 0)))
           (post! (cons 'connected c))
           (let lp ()
             (let (frames (read-frames (connection-device c) reader buffer))
               (when frames
                 (post! (cons 'frames frames))
                 (lp))))
           'ended))))))

(def (error-message (e : :t)) => :string
  (let (text (and (error-object? e) (error-object-message e)))
    (if (string? text) text "error")))

(def (send! (term : live-terminal) (type : :symbol) (payload : :u8vector := (u8vector))) => :void
  (let (c term.link)
    (when c (connection-send! c type payload))))

;;; What the helper sends

(def (receive! (self : terminals-state) (term : live-terminal) (result : :t)) => :void
  (keep-poster! self)
  (when (and (eq? (hash-get self.terms (terminal-id term)) term) (not self.stopping?))
    (cond
     ((and (pair? result) (eq? (car result) 'connected))
      (set! term.link (cdr result)))
     ((and (pair? result) (eq? (car result) 'frames))
      (for-each (cut receive-frame! self term <>) (cdr result)))
     ((and (pair? result) (eq? (car result) 'failed))
      (message (string-append (terminal-id-name term) ": " (cdr result)))
      (helper-gone! self term))
     ((memq result '(ended gone))
      (set! term.link #f)
      (unless (terminal-exit-status term)
        (helper-gone! self term))))))

(def (terminal-id-name (term : live-terminal)) => :string
  (buffer-name (terminal-buffer term)))

(def (receive-frame! (self : terminals-state) (term : live-terminal) (f : frame)) => :void
  (let (payload (frame-payload f))
    (case (frame-type f)
      ((hello)
       (let (h (parse-helper-hello payload))
         (if (fx= (helper-hello-version h) protocol-version)
           (begin
             (set! term.helper-pid (helper-hello-helper-pid h))
             (set! term.child-pid (helper-hello-child-pid h))
             (set! term.refusals 0)
             (set! term.columns (helper-hello-columns h))
             (set! term.rows (helper-hello-rows h))
             (set-node-attribute! term.root 'size (size-text term))
             ;; Views measured while it was starting, or since the last
             ;; Tuna saw it, may want another size.
             (resize-to-views! self term))
           (message (string-append (terminal-id-name term)
                                   ": its helper is from another version of Tuna; it runs on, unshown")))))
      ((snapshot) (adopt-snapshot! self term payload))
      ((output)
       (let (mirror term.mirror)
         (when mirror
           (terminal-write! mirror payload)
           (set! term.last-output (now))
           (apply-effects! self term)
           (output-arrived! self term))))
      ((exit) (program-ended! self term (parse-exit payload)))
      ((refused)
       (set! term.link #f)
       (if (and (equal? (utf8->string payload) "busy") (fx< term.refusals 50))
         ;; The helper has not yet seen the last connection go (a swap).
         (begin
           (set! term.refusals (fx1+ term.refusals))
           (context-run-with-timer! self.ctx 0.1 #f
                                    (lambda ()
                                      (when (eq? (hash-get self.terms (terminal-id term)) term)
                                        (start-reader! self term #f)))
                                    name: 'terminal-reconnect))
         (message (string-append (terminal-id-name term) ": its helper refused to connect ("
                                 (utf8->string payload) ")"))))
      (else (void)))))

;; The helper's terminal, as a snapshot, becomes TERM's mirror.
(def (adopt-snapshot! (self : terminals-state) (term : live-terminal) (bytes : :u8vector)) => :void
  (let ((old term.mirror)
        (mirror (snapshot-bytes->terminal bytes)))
    (when old (terminal-close! old))
    (terminal-set-scrollback-max-bytes! mirror (setting-value terminal-max-scrollback))
    (terminal-set-title-changed-handler! mirror (lambda (title) (push-effect! term (cons 'title title))))
    (terminal-set-pwd-changed-handler! mirror (lambda (directory) (push-effect! term (cons 'directory directory))))
    (terminal-set-bell-handler! mirror (lambda () (push-effect! term '(bell))))
    (terminal-set-semantic-prompt-handler! mirror
                                           (lambda (event) (push-effect! term (cons 'prompt (semantic-prompt-event-kind event)))))
    (set! term.mirror mirror)
    ;; A new mirror numbers its rows anew: every row is copied again.
    (set! (row-store-generation term.primary) #f)
    (set! (row-store-generation term.alternate) #f)
    (sync! self term)))

;; Handlers only queue: they run inside the mirror's write, which must not
;; call back into Tuna.
(def (push-effect! (term : live-terminal) (effect : :pair)) => :void
  (set! term.effects (cons effect term.effects)))

(def (apply-effects! (self : terminals-state) (term : live-terminal)) => :void
  (let (effects (reverse term.effects))
    (set! term.effects [])
    (for-each
     (lambda ((effect : :pair))
       (case (car effect)
         ((title) (title-changed! self term (lenient-utf8 (cdr effect))))
         ((directory) (directory-reported! self term (lenient-utf8 (cdr effect))))
         ((bell) (run-hook-safely terminal-bell-hook term))
         ((prompt)
          (case (cdr effect)
            ((output-start) (set! term.running? #t))
            ((prompt-start command-end) (set! term.running? #f))
            (else (void))))
         (else (void))))
     effects)))

(def (lenient-utf8 (bytes : :u8vector)) => :string
  (:- (with-catch (lambda (e) (list->string (map integer->char (u8vector->list bytes))))
                  (lambda () (utf8->string bytes)))
      :string))

(def (run-hook-safely (hook : :t) . args) => :void
  (with-catch (lambda (e) (message (string-append "Terminal hook failed: " (error-message e))))
              (lambda () (apply run-hook hook args))))

;;; Titles and folders

(def (title-changed! (self : terminals-state) (term : live-terminal) (title : :string)) => :void
  (set! term.title title)
  (when (eq? (buffer-local-value terminal-buffer-name-function (terminal-buffer term)) 'title)
    (rename-managed! self term (if (string-empty? title)
                                 term.initial-name
                                 (string-append "*terminal: " title "*"))))
  (run-hook-safely terminal-title-hook term title))

;; Rename TERM's buffer to NAME, unless the user renamed it since we did.
(def (rename-managed! (self : terminals-state) (term : live-terminal) (name : :string)) => :void
  (let (b (terminal-buffer term))
    (when (and term.managed-name (equal? (buffer-name b) term.managed-name)
               (not (equal? name (buffer-name b))))
      (let (unique (unique-buffer-name name))
        (rename-buffer! b unique)
        (set! term.managed-name unique)))))

;; The local folder REPORT (an OSC 7 payload) names, or #f: a
;; kitty-shell-cwd:// URL (the path as it is), a file:// URL (the path
;; percent-decoded), or a plain path; a URL naming another host is not
;; local, and a URL of another scheme is ignored.
(def (parse-directory-report (report : :string) (host : :string)) => (Maybe :string)
  (def (after-scheme (scheme : :string)) => (Maybe :string)
    (let (prefix (string-append scheme "://"))
      (and (string-prefix? prefix report) (substring report (string-length prefix) (string-length report)))))
  (let* ((kitty (after-scheme "kitty-shell-cwd"))
         (file (and (not kitty) (after-scheme "file")))
         (rest (or kitty file)))
    (cond
     (rest
      (let (slash (string-index rest #\/))
        (and slash
             (let ((url-host (string-downcase (substring rest 0 slash)))
                   (path (substring rest slash (string-length rest))))
               (and (member url-host ["" "localhost" (string-downcase host)])
                    (if file (percent-decode path) path))))))
     ((string-index report #\:) #f)
     ((string-prefix? "/" report) report)
     (else #f))))

(def (percent-decode (s : :string)) => :string
  (let (bytes (string->utf8 s))
    (let lp ((i 0) (out []))
      (cond
       ((fx>= i (u8vector-length bytes)) (lenient-utf8 (list->u8vector (reverse out))))
       ((and (fx= (u8vector-ref bytes i) 37) (fx< (fx+ i 2) (u8vector-length bytes))
             (string->number (utf8->string (subu8vector bytes (fx1+ i) (fx+ i 3))) 16))
        => (lambda (n) (lp (fx+ i 3) (cons n out))))
       (else (lp (fx1+ i) (cons (u8vector-ref bytes i) out)))))))

(def (host-name) => :string
  (:- (with-catch (lambda (e) "")
                  (lambda () (string-trim (call-with-input-file "/proc/sys/kernel/hostname" read-line))))
      :string))

(def (string-trim (s : :t)) => :string
  (if (string? s) s ""))

(def (directory-reported! (self : terminals-state) (term : live-terminal) (report : :string)) => :void
  (let (path (parse-directory-report report (host-name)))
    (when (and path (file-exists? path) (eq? (file-info-type (file-info path)) 'directory)
               (not (equal? path (terminal-directory term))))
      (let ((b (terminal-buffer term))
            (folder (if (string-suffix? "/" path) path (string-append path "/"))))
        (set! term.directory path)
        (set-buffer-setting! b default-directory folder)
        (when (eq? (buffer-local-value terminal-buffer-name-function b) 'directory)
          (rename-managed! self term (string-append "*terminal: " (abbreviated path) "*")))
        (run-hook-safely terminal-directory-hook term path)))))

(def (abbreviated (path : :string)) => :string
  (let (home (or (getenv "HOME" #f) ""))
    (if (and (not (string-empty? home)) (string-prefix? home path))
      (string-append "~" (substring path (string-length home) (string-length path)))
      path)))

;;; Drawing

;; Output arrived: draw it now when it is the echo of a key or follows a
;; quiet spell, else at the next tick of TERM's timer.
(def (output-arrived! (self : terminals-state) (term : live-terminal)) => :void
  (let ((t (now))
        (quiet? (and (setting-value terminal-adaptive-fps)
                     (> (- (now) term.last-output) 0.1))))
    (if (or (< (- t term.last-input) (setting-value terminal-immediate-redraw-interval)) quiet?)
      (sync! self term)
      (begin
        (set! term.sync-due? #t)
        (restart-timer term.timer)))))

;; The row nodes of TERM's mirror's screen made current, its root showing
;; that screen, and the views following its output at its bottom.
(def (sync! (self : terminals-state) (term : live-terminal)) => :void
  (set! term.sync-due? #f)
  (let (mirror term.mirror)
    (when mirror
      (let* ((following (filter (cut following? self term <>) (views-showing term)))
             (changes (terminal-copy-changed-rows! mirror))
             (numbering (row-changes-numbering changes))
             (screen (row-numbering-screen numbering))
             (store (if (eq? screen 'alternate) term.alternate term.primary))
             (first (row-numbering-first-row numbering))
             (end (+ first (row-numbering-total-rows numbering))))
        (if (eqv? (row-store-generation store) (row-numbering-generation numbering))
          (begin
            (row-store-trim! store first)
            (row-store-extend! store end)
            (let ((from (max first (row-changes-frozen-start changes)))
                  (to (min end (row-changes-frozen-end changes))))
              (when (< from to) (copy-rows! store mirror from to)))
            (vector-for-each (lambda (row) (set-row! store row)) (row-changes-rows changes)))
          (begin
            (row-store-reset! store (row-numbering-generation numbering) first)
            (row-store-extend! store end)
            (copy-rows! store mirror first end)
            (vector-for-each (lambda (row) (set-row! store row)) (row-changes-rows changes))))
        (move-cursor! term store (row-changes-cursor changes))
        (let (blocks (row-store-blocks store))
          (unless (and (eq? screen term.screen) (equal? (map node-id blocks) (map node-id (node-children term.root))))
            (set-node-attribute! term.root 'screen screen)
            (set-node-children! term.root blocks)))
        (set! term.screen screen)
        (end-long-hold! term mirror)
        (for-each (cut place-at-bottom! term <>) following)))))

;; Copy rows FROM to TO of MIRROR into STORE, a thousand at a time.
(def (copy-rows! (store : row-store) (mirror : :t) (from : :integer) (to : :integer)) => :void
  (let lp ((from from))
    (when (< from to)
      (let (upto (min to (+ from 1000)))
        (vector-for-each (lambda (row) (set-row! store row)) (terminal-copy-rows mirror from upto))
        (lp upto)))))

(def (set-row! (store : row-store) (row : :t)) => :void
  (let (n (row-store-row store (styled-row-number row)))
    (when n (set-node-attribute! n 'runs (row-runs row)))))

(def (move-cursor! (term : live-terminal) (store : row-store) (cursor : :t)) => :void
  (let* ((number (and cursor (row-cursor-visible? cursor) (row-cursor-row cursor)))
         (n (and number (row-store-row store number)))
         (old term.cursor-row))
    (when (and old (not (eq? old n)))
      (set-node-attribute! old 'cursor #f))
    (when n
      (set-node-attribute! n 'cursor
                           (vector (row-cursor-x cursor)
                                   (if (setting-value terminal-ignore-cursor-change) 'block (row-cursor-style cursor))
                                   (and (row-cursor-blinking? cursor) #t))))
    (set! term.cursor-row n)))

;; Synchronized output holds the drawn frame; a program that never lets go
;; is let go after a second.
(def (end-long-hold! (term : live-terminal) (mirror : :t)) => :void
  (if (terminal-render-held? mirror)
    (let (since term.held-since)
      (cond
       ((not since) (set! term.held-since (now)) (restart-timer term.timer) (set! term.sync-due? #t))
       ((> (- (now) since) 1.0) (terminal-end-render-hold! mirror) (set! term.held-since #f))
       (else (set! term.sync-due? #t) (restart-timer term.timer))))
    (set! term.held-since #f)))

;; TERM's last row node, as an item, or #f.
(def (last-row-item (term : live-terminal)) => (Maybe item)
  (let (n (row-store-last-row (if (eq? term.screen 'alternate) term.alternate term.primary)))
    (and n (node-item n))))

;; Whether V, showing TERM, is at its bottom: still where it was put to
;; follow output, or a browser measured its last row in view.
(def (following? (self : terminals-state) (term : live-terminal) (v : view)) => :boolean
  (let ((placed (hash-get term.follow v))
        (last (last-row-item term)))
    (or (not last)
        (eqv? placed (placement-number (view-placement v)))
        (ormap (lambda ((c : client))
                 (let* ((cv (view-client v c))
                        (facts (client-view-facts cv)))
                   (and facts
                        (fx= (scroll-facts-placement facts) (placement-number (client-view-placement cv)))
                        (let (seen (scroll-facts-last-visible facts))
                          (and seen (eq? (item-node seen) (item-node last)))))))
               (hash-keys self.sizes)))))

(def (place-at-bottom! (term : live-terminal) (v : view)) => :void
  (let (last (last-row-item term))
    (when last
      (place-view! v last 'bottom)
      (hash-put! term.follow v (placement-number (view-placement v))))))

;;; Sizes

;; What CLIENT's page measured: (VIEW-ID TERMINAL-ID COLUMNS ROWS
;; CELL-WIDTH CELL-HEIGHT) for each terminal it shows.
(def (sizes-measured! (self : terminals-state) (c : client) (measured : :list)) => :void
  (hash-put! self.sizes c measured)
  (for-each (cut resize-to-views! self <>) (hash-values self.terms)))

;; Size TERM to the smallest view showing it, as Emacs sizes a process's
;; window (window-adjust-process-window-size-smallest).
(def (resize-to-views! (self : terminals-state) (term : live-terminal)) => :void
  (let* ((view-ids (map view-id (views-showing term)))
         (sizes (filter (lambda ((m : :list)) (and (memv (car m) view-ids) (equal? (cadr m) (terminal-id term))))
                        (apply append (hash-values self.sizes)))))
    (when (pair? sizes)
      (let ((columns (apply min (map caddr sizes)))
            (rows (apply min (map cadddr sizes)))
            (width (list-ref (car sizes) 4))
            (height (list-ref (car sizes) 5)))
        (unless (and (fx= columns term.columns) (fx= rows term.rows)
                     (fx= width term.cell-width) (fx= height term.cell-height))
          (set! term.columns columns)
          (set! term.rows rows)
          (set! term.cell-width width)
          (set! term.cell-height height)
          (set-node-attribute! term.root 'size (size-text term))
          (request-size! term))))))

;; TERM's size as its element names it for the page script: COLUMNSxROWS.
(def (size-text (term : live-terminal)) => :string
  (string-append (number->string term.columns) "x" (number->string term.rows)))

;; Ask TERM's helper for TERM's size. Its snapshot after resizing replaces
;; the mirror, so output written for the old size is never parsed at the
;; new.
(def (request-size! (term : live-terminal)) => :void
  (send! term 'resize (resize-payload (make-resize-request term.columns term.rows term.cell-width term.cell-height)))
  (send! term 'snapshot-request))

;; Parse a page's measurements, as JSON: [{view, terminal, columns, rows,
;; cellWidth, cellHeight}, ...]; #f when they are not.
(def (parse-measurements (bytes : :u8vector)) => (Maybe :list)
  (:? (with-catch
   (lambda (e) #f)
   (lambda ()
     (let (data (parameterize ((current-json-read-options (JSONReadOptions object-as-hash: #t)))
                   (string->json (utf8->string bytes))))
       (and (list? data)
            (filter-map
             (lambda (entry)
               (and (hash-table? entry)
                    (let ((view (hash-get entry "view"))
                          (id (hash-get entry "terminal"))
                          (numbers (map (lambda (key) (hash-get entry key))
                                        ["columns" "rows" "cellWidth" "cellHeight"])))
                      (and (fixnum? view) (string? id)
                           (andmap (lambda (n) (and (real? n) (< 0 n 10000))) numbers)
                           (let (whole (map (lambda (n) (inexact->exact (floor n))) numbers))
                             (and (fx> (car whole) 0) (fx> (cadr whole) 0)
                                  (cons* view id whole)))))))
             data))))) :list))

;;; Input

(def (send-input! (self : terminals-state) (term : live-terminal) (bytes : :u8vector)) => :void
  (when (and (fx> (u8vector-length bytes) 0) term.link (not (terminal-exit-status term)))
    (set! term.last-input (now))
    (when (setting-value terminal-scroll-on-input)
      (for-each (cut place-at-bottom! term <>) (views-showing term)))
    (send! term 'input bytes)))

;; The terminal of the current buffer, or an error saying there is none.
(def (this-terminal (self : terminals-state)) => live-terminal
  (or (current-terminal self) (error "This buffer is not a terminal")))

;; EVENT, a browser key, as the bytes TERM's program asked for.
(def (key-bytes (self : terminals-state) (term : live-terminal) (event : key-event)) => :u8vector
  (let* ((ge (terminal-key-event event))
         (encoded (if (and ge term.mirror) (key-encoder-encode self.encoder ge terminal: term.mirror) (u8vector))))
    (if (and (fx= (u8vector-length encoded) 0) (fx= (string-length (key-event-key event)) 1))
      (string->utf8 (key-event-key event))
      encoded)))

(def (send-key! (self : terminals-state) (event : :t)) => :void
  (let (term (this-terminal self))
    (when (key-event? event)
      (send-input! self term (key-bytes self term event)))))

(def (mode-on? (term : live-terminal) (name : :symbol)) => :boolean
  (let ((mirror term.mirror)
        (mode (assq name (terminal-modes))))
    (and mirror mode (terminal-mode-enabled? mirror (cdr mode)))))

;; Send TEXT as a paste: bracketed when the program asked for it.
(def (paste! (self : terminals-state) (term : live-terminal) (text : :string)) => :void
  (send-input! self term (paste-encode (string->utf8 text) bracketed?: (mode-on? term 'bracketed-paste))))

(def (set-input-mode! (self : terminals-state) (term : live-terminal) (mode : :symbol)) => :void
  (set! term.input-mode mode)
  (set-node-keymap! term.root (if (eq? mode 'char) self.char-map self.semi-char))
  (message (if (eq? mode 'char)
             "Terminal char mode: every key goes to the program; M-RET goes back"
             "Terminal semi-char mode")))

;; Ask for one key in the minibuffer and send it, whatever it is
;; (ghostel-send-next-key).
(def (send-next-key! (self : terminals-state)) => :void
  (let* ((term (this-terminal self))
         (asked #f)
         (event (unwind-protect
                  (read-from-minibuffer "Send key: "
                                        setup: (lambda ((p : Prompt))
                                                 (set! asked p)
                                                 (set! self.quoting (cons p self.quoting))
                                                 (set-node-keymap! (prompt-answer-node p) self.quote-map)))
                  (set! self.quoting (remq asked self.quoting)))))
    (when (key-event? event)
      (send-input! self term (key-bytes self term event)))))

;;; Exits and kills

(def (program-ended! (self : terminals-state) (term : live-terminal) (status : :fixnum)) => :void
  (unless (terminal-exit-status term)
    (set! term.exit-status status)
    (sync! self term)
    (run-hook-safely terminal-exit-hook term status)
    (send! term 'exit-ack)
    (let (c term.link)
      (when c (close-connection! c)))
    (set! term.link #f)
    (if (buffer-local-value terminal-kill-buffer-on-exit (terminal-buffer term))
      (kill-buffer (terminal-buffer term))
      (let (mirror term.mirror)
        (when mirror
          ;; As ghostel: a readable charset, no held frame, then the note.
          (terminal-write! mirror (string->utf8 "\x1b;[!p\x1b;[?2026l\r\n[Process exited]\r\n"))
          (sync! self term))))))

;; The helper went away without its program's exit: show so; the terminal
;; stays, dead.
(def (helper-gone! (self : terminals-state) (term : live-terminal)) => :void
  (unless (terminal-exit-status term)
    (set! term.exit-status 255)
    (let (mirror term.mirror)
      (when mirror
        (terminal-write! mirror (string->utf8 "\x1b;[!p\x1b;[?2026l\r\n[Terminal helper gone]\r\n"))
        (sync! self term)))))

;; Whether a command, not just the shell, runs in TERM: OSC 133 says so,
;; or the terminal's foreground process group is not the shell's.
(def (command-running? (term : live-terminal)) => :boolean
  (or term.running?
      (let (pid term.child-pid)
        (and (fx> pid 0)
             (:- (with-catch
              (lambda (e) #f)
              (lambda ()
                (let* ((stat (call-with-input-file (string-append "/proc/" (number->string pid) "/stat") read-line))
                       (close (string-rindex stat #\)))
                       (fields (string-split (substring stat (fx+ close 2) (string-length stat)) #\space))
                       (foreground (string->number (list-ref fields 5))))
                  (and foreground (fx> foreground 0) (not (fx= foreground pid))))))
                 :boolean)))))

(def (query-before-killing? (term : live-terminal)) => :boolean
  (and (not (terminal-exit-status term))
       (case (buffer-local-value terminal-query-before-killing (terminal-buffer term))
         ((#t) #t)
         ((auto) (command-running? term))
         (else #f))))

;; Ask QUESTION until the answer is "yes" or "no" (Emacs yes-or-no-p).
(def (yes-or-no? (question : :string)) => :boolean
  (let lp ()
    (let (answer (read-string (string-append question "(yes or no) ")))
      (cond
       ((equal? answer "yes") #t)
       ((equal? answer "no") #f)
       (else (message "Please answer yes or no.") (lp))))))

;; Forget TERM, its buffer killed: end its program and helper when KILL?,
;; else leave them running.
(def (forget! (self : terminals-state) (term : live-terminal) (kill? : :boolean)) => :void
  (hash-remove! self.terms (terminal-id term))
  (hash-remove! self.by-buffer (terminal-buffer term))
  (when (eq? self.focused term) (set! self.focused #f))
  (let (c term.link)
    (when c
      (when (and kill? (not (terminal-exit-status term)))
        (connection-send! c 'kill))
      (close-connection! c)))
  (set! term.link #f)
  (let (j term.reader) (when j (job-cancel! j)))
  (let (t term.timer) (when t (cancel-timer t)))
  (let (mirror term.mirror)
    (when mirror (terminal-close! mirror)))
  (set! term.mirror #f))

;;; Starting terminals

(def (terminal-size-guess (self : terminals-state)) => :pair
  (let* ((v (and (service-there? layout-service) (selected-view)))
         (measured (and v (find (lambda ((m : :list)) (eqv? (car m) (view-id v)))
                                (apply append (hash-values self.sizes))))))
    (if measured (cons (caddr measured) (cadddr measured)) (cons 80 24))))

;; A new terminal running the shell in the current buffer's folder, named
;; NAME, shown in the selected view.
(def (start-terminal! (self : terminals-state) (name : :string)) => live-terminal
  (keep-poster! self)
  (let* ((directory (buffer-default-directory (current-buffer)))
         (id (new-terminal-id))
         (socket (path-expand (string-append id ".sock") (socket-directory)))
         (size (terminal-size-guess self))
         (mode (if (eq? (setting-value terminal-initial-input-mode) 'char) 'char 'semi-char))
         (term (new-live-terminal self id socket name mode (car size) (cdr size)))
         (b (terminal-buffer term))
         (launch (make-helper-launch (:- (plugin-option terminals 'helper) :string) socket (car size) (cdr size)
                                     (setting-value terminal-max-scrollback)
                                     (if (string-suffix? "/" directory)
                                       (substring directory 0 (fxmax 1 (fx1- (string-length directory))))
                                       directory)
                                     (path-expand (string-append id ".log") (path-directory socket))
                                     (shell-command)
                                     (terminal-process-environment (setting-value terminal-environment)
                                                                   (setting-value terminal-term)
                                                                   (:- (plugin-option terminals 'terminfo) :string)
                                                                   directory (process-environment))
                                     (and (leave-scope?) (string-append "tuna-terminal-" id)))))
    (set-buffer-setting! b default-directory directory)
    (switch-to-buffer b)
    (start-reader! self term launch)
    term))

;; The terminal buffer named NAME, made when there is none.
(def (find-or-start! (self : terminals-state) (name : :string)) => :void
  (let* ((b (get-buffer name))
         (term (and b (hash-get self.by-buffer b))))
    (if term
      (switch-to-buffer (terminal-buffer term))
      (start-terminal! self (unique-buffer-name name)))))

;;; The session

;; Each live terminal: (ID SOCKET BUFFER-NAME INPUT-MODE VIEW-IDS).
(def (save-terminals (self : terminals-state)) => :list
  (filter-map (lambda ((term : live-terminal))
                (and (not (terminal-exit-status term))
                     [(terminal-id term) term.socket (buffer-name (terminal-buffer term))
                      term.input-mode (map view-id (views-showing term))]))
              (hash-values self.terms)))

(def (restore-terminals! (self : terminals-state) (data : :t)) => :void
  (when (list? data)
    (for-each
     (lambda (entry)
       (match entry
         ([(? string? id) (? string? socket) (? string? name) (? symbol? mode) (? list? view-ids)]
          (when (and (file-exists? socket) (not (hash-get self.terms id)))
            (let* ((term (new-live-terminal self id socket (unique-buffer-name name) mode 80 24)))
              (start-reader! self term #f)
              ;; A swap left these views showing another buffer.
              (when (service-there? layout-service)
                (for-each (lambda ((v : view))
                            (when (memv (view-id v) view-ids)
                              (set-view-buffer v (terminal-buffer term))))
                          (view-list))))))
         (else (void))))
     data)))

;;; Focus

;; Tell the programs of the terminals the selected view starts or stops
;; showing (mode 1004 focus events, sent only to programs that ask).
(def (track-focus! (self : terminals-state)) => :void
  (let (term (current-terminal self))
    (unless (eq? term self.focused)
      (let (old self.focused)
        (when old (send! old 'focus (u8vector 0))))
      (when term (send! term 'focus (u8vector 1)))
      (set! self.focused term))))

;;; Drawing nodes

(def (render-terminal (self : terminals-state) (n : node) (children : :list)) => :t
  `(div (@ (class ,(if (eq? (node-attribute n 'screen) 'alternate) "terminal terminal-alternate" "terminal"))
           (data-terminal ,(node-attribute n 'id))
           (data-size ,(or (node-attribute n 'size) "")))
        (div (@ (class "terminal-row terminal-measure") (aria-hidden "true")) "MMMMMMMMMM")
        ,@children))

;;; Options

(def key-list-type
  (make-option-type "a list of key strings, as \"C-c\"" (lambda (v) (and (list? v) (andmap string? v)))
                    (lambda (text) (string-split text #\,))))

(def scope-type
  (make-option-type "auto, always or never" (cut memq <> '(auto always never)) string->symbol))

(defplugin (terminals ctx)
  "M-x terminal: a shell in a buffer, in a helper process that survives Tuna restarting."
  requires: [commands-service input-service settings-service buffers-service session-service]
  optional: [layout-service minibuffer-service editing-service files-service file-system-service page-service]
  (add-stylesheet 'tokens "tokens.css")
  (add-stylesheet 'rules "rules.css")
  (using (self (terminals-state ctx: ctx terms: (make-hash-table) by-buffer: (make-hash-table-eq)
                                semi-char: (new-keymap) char-map: (new-keymap) quote-map: (new-keymap)
                                jobs: (new-job-group ctx) encoder: (make-key-encoder) sizes: (make-hash-table-eq)
                                quoting: [] poster: #f focused: #f yank: 0 waiting: [] stopping?: #f)
               : terminals-state)
    (context-define-node-kind! ctx 'terminal doc: "A terminal: its rows, scrollback then screen." items: 'children)
    (context-define-node-kind! ctx 'terminal-rows doc: "A run of a terminal's rows." items: 'children)
    (context-define-node-kind! ctx 'terminal-row doc: "One row of a terminal." items: 'whole
                               project: (lambda (n) (apply string-append
                                                           (map (cut vector-ref <> 2)
                                                                (vector->list (node-attribute n 'runs))))))
    (context-define-node-renderer! ctx 'terminal (lambda (n children) (render-terminal self n children)))
    (context-define-node-renderer! ctx 'terminal-rows (lambda (n children) `(div (@ (class "terminal-rows")) ,@children)))
    (context-define-node-renderer! ctx 'terminal-row
                                   (lambda (n children)
                                     `(div (@ (class "terminal-row"))
                                           ,@(row-sxml (node-attribute n 'runs) (node-attribute n 'cursor)))))
    (when (service-there? page-service)
      (add-script ctx "web/terminal.js")
      (context-add-page-address! ctx "size"
                                 (lambda (c bytes)
                                   (let ((measured (parse-measurements bytes))
                                         (post self.poster))
                                     (when (and measured post)
                                       (post 'terminal-size (lambda () (sizes-measured! self c measured))))))))
    (context-add-hook! ctx client-gone-hook 'terminal
                       (lambda (c) (hash-remove! self.sizes c)))
    (context-add-hook! ctx kill-buffer-hook 'terminal
                       (lambda (b)
                         (let (term (hash-get self.by-buffer b))
                           (when term (forget! self term (not self.stopping?))))))
    (context-add-kill-buffer-query! ctx 'terminal
                                    (lambda (b)
                                      (let (term (hash-get self.by-buffer b))
                                        (or (not term) (not (query-before-killing? term))
                                            (not (service-there? minibuffer-service))
                                            (yes-or-no? (string-append "Buffer " (buffer-name b)
                                                                       " has a running process; kill it? "))))))
    (context-add-hook! ctx post-command-hook 'terminal-focus (lambda () (track-focus! self)))
    (context-add-hook! ctx task-started-hook 'terminal
                       (lambda (id name)
                         (let (waiting self.waiting)
                           (when (pair? waiting)
                             (set! self.waiting [])
                             (for-each (lambda ((term : live-terminal))
                                         (when (eq? (hash-get self.terms (terminal-id term)) term)
                                           (start-reader! self term #f)))
                                       (reverse waiting))))))
    (context-add-session-slot! ctx 'terminals version: 1
                               save: (lambda () (save-terminals self))
                               restore: (lambda (data) (restore-terminals! self data)))

    ;; Commands
    (define-command ctx (terminal) "Show the terminal buffer, starting a shell in one when there is none."
      (find-or-start! self (setting-value terminal-buffer-name)))
    (define-command ctx (terminal-new) "Start a new terminal running the shell, in a buffer of its own."
      (start-terminal! self (unique-buffer-name (setting-value terminal-buffer-name))))
    (define-command ctx (terminal-send-key) "Send the key typed to the terminal's program."
      (send-key! self (last-command-event)))
    (define-command ctx (terminal-send-next-key) "Read one key and send it to the terminal's program, whatever it is."
      (send-next-key! self))
    (define-command ctx (terminal-quoted-key) "Answer the terminal's request for one key with the key typed."
      (match self.quoting
        ([p . _] (prompt-exit! p (last-command-event) history-text: ""))
        (else (void))))
    (define-command ctx (terminal-send-C-c) "Send C-c, an interrupt, to the terminal's program."
      (send-input! self (this-terminal self) (u8vector 3)))
    (define-command ctx (terminal-send-C-z) "Send C-z, a suspend, to the terminal's program."
      (send-input! self (this-terminal self) (u8vector 26)))
    (define-command ctx (terminal-send-C-backslash) "Send C-\\, a quit, to the terminal's program."
      (send-input! self (this-terminal self) (u8vector 28)))
    (define-command ctx (terminal-send-C-d) "Send C-d, an end of input, to the terminal's program."
      (send-input! self (this-terminal self) (u8vector 4)))
    (define-command ctx (terminal-send-C-g) "Send C-g to the terminal's program."
      (send-input! self (this-terminal self) (u8vector 7)))
    (define-command ctx (terminal-paste) "Send the text the browser pasted to the terminal's program."
      (let (event (last-command-event))
        (when (paste-event? event)
          (paste! self (this-terminal self) (paste-event-text event)))))
    (define-command ctx (terminal-yank) "Send the newest killed text to the terminal's program, as a paste."
      (let (term (this-terminal self))
        (set! self.yank 0)
        (when (service-there? editing-service)
          (paste! self term (current-kill 0)))))
    (define-command ctx (terminal-yank-pop) "Replace the text just yanked into the terminal with the kill before it."
      (let (term (this-terminal self))
        (when (and (service-there? editing-service) (memq (last-command) '(terminal-yank terminal-yank-pop)))
          (let (previous (current-kill self.yank))
            (set! self.yank (fx1+ self.yank))
            (send-input! self term (make-u8vector (string-length previous) 127))
            (paste! self term (current-kill self.yank))))))
    (define-command ctx (terminal-semi-char-mode) "Send most keys to the terminal's program, keeping C-c, C-x, M-x and the like."
      (set-input-mode! self (this-terminal self) 'semi-char))
    (define-command ctx (terminal-char-mode) "Send every key to the terminal's program; M-RET goes back to semi-char mode."
      (set-input-mode! self (this-terminal self) 'char))

    ;; Keymaps
    (let ((exceptions (:- (plugin-option terminals 'keymap-exceptions) :list))
          (bind (lambda ((keymap : entry-table) (keys : :string) (command : :symbol))
                  (keymap-set-in! ctx keymap keys command "plugins/terminal/plugin.ss"))))
      (for-each (lambda ((keymap : entry-table) (char-mode? : :boolean))
                  (for-each (cut bind keymap <> 'terminal-send-key) (terminal-key-names exceptions char-mode?))
                  (bind keymap printing-char-key 'terminal-send-key))
                [self.semi-char self.char-map] [#f #t])
      (for-each (lambda ((binding : :pair)) (bind self.semi-char (car binding) (cdr binding)))
                '(("C-c C-c" . terminal-send-C-c) ("C-c C-z" . terminal-send-C-z)
                  ("C-c C-\\" . terminal-send-C-backslash) ("C-c C-d" . terminal-send-C-d)
                  ("C-c C-q" . terminal-send-next-key) ("C-c C-y" . terminal-yank)
                  ("C-c C-j" . terminal-semi-char-mode) ("C-c M-d" . terminal-char-mode)
                  ("C-y" . terminal-yank) ("S-<insert>" . terminal-yank) ("M-y" . terminal-yank-pop)
                  ("<paste>" . terminal-paste)))
      (unless (member "C-q" exceptions) (bind self.semi-char "C-q" 'terminal-send-next-key))
      (unless (member "C-g" exceptions) (bind self.semi-char "C-g" 'terminal-send-C-g))
      (for-each (lambda ((keys : :string)) (bind self.char-map keys 'terminal-semi-char-mode))
                ["M-RET" "C-M-m"])
      (bind self.char-map "<paste>" 'terminal-paste)
      (for-each (cut bind self.quote-map <> 'terminal-quoted-key)
                (append (terminal-key-names [] #t) [printing-char-key "C-q" "C-x" "C-c" "M-x" "C-u" "C-h"])))

    ;; Turning off leaves every helper running: it is how a swap, a reload
    ;; or Tuna stopping keep their programs.
    (context-defer! ctx
                    (lambda ()
                      (set! self.stopping? #t)
                      (for-each (lambda ((term : live-terminal))
                                  (let (b (terminal-buffer term))
                                    (forget! self term #f)
                                    (with-catch void (lambda () (kill-buffer b)))))
                                (hash-values self.terms))))))

(defplugin-options terminals
  (helper default-helper-path
          "The terminal helper program; `make` builds it into .gerbil/bin."
          string-type)
  (terminfo default-terminfo-directory
            "The folder of the compiled xterm-ghostty terminfo entry; `make` builds it into .gerbil/terminfo."
            string-type)
  (socket-directory ""
                    "The private folder holding helpers' sockets; \"\" for $XDG_RUNTIME_DIR/tuna/terminals."
                    string-type)
  (leave-scope 'auto
               "Whether helpers leave Tuna's systemd scope, which would kill them with it: auto (when Tuna runs in one), always or never."
               scope-type)
  (keymap-exceptions default-keymap-exceptions
                     "The keys a terminal in semi-char mode keeps for Tuna (ghostel-keymap-exceptions)."
                     key-list-type))
