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
;;; the job's apply, on the editor thread, a batch at a time (the reader
;;; waits while `terminal-input-buffer-size` bytes wait, so a flood holds
;;; the program back rather than filling Tuna). Drawing reads only the
;;; mirror: after output, the rows that changed are copied into row nodes
;;; (screen.ss), paced as ghostel paces its redraws: at once after a key
;;; (`terminal-immediate-redraw-interval`), else by a timer that coalesces
;;; what arrives meanwhile (`terminal-timer-delay`, sooner after a quiet
;;; spell with `terminal-adaptive-fps`). Rows that left the screen are
;;; copied at once only near the bottom; older ones once output pauses, so
;;; a flood does not copy rows it trims before anyone sees them. A terminal
;;; no view shows is copied once one does. Plain links are looked for after
;;; `terminal-plain-link-detection-delay`. A view showing a terminal at its
;;; bottom follows its output; one scrolled up stays put. The alternate
;;; screen (vim, htop) is a grid of the screen's rows without scrollback.
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
;;;
;;; What else programs say (stage 4) runs the contract's hooks and nothing
;;; more, as ghostel's terminal leaves it to ghostel-status and the hooks:
;;; a shell's prompts and commands (OSC 133), notifications (OSC 9, 777),
;;; progress (OSC 9;4), program status (OSC 7501), full resets and
;;; sequences libghostty does not know. The plugin itself uses the prompt
;;; marks for prompt navigation (C-c M-n, C-c M-p), which enters copy mode
;;; as ghostel's does.

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
        (only-in :tuna/plugins/renderer/contract renderer-service context-add-status-line-part!)
        (only-in :tuna/lib/memo source new-source record-read! source-changed!)
        (only-in :tuna/plugins/editing/contract editing-service current-kill kill-new
                 region-active? region-beginning region-end set-temporary-region!)
        (only-in :tuna/plugins/files/contract files-service file-system-service
                 default-directory buffer-default-directory find-file-noselect)
        (only-in :tuna/plugins/web/contract page-service add-script context-add-page-address! page-instruct!)
        :tuna/plugins/terminal/contract
        (only-in :gerbil-libghostty/ghostty
                 snapshot-bytes->terminal terminal-write! terminal-close! terminal-resize!
                 terminal-set-scrollback-max-bytes! terminal-set-title-changed-handler!
                 terminal-set-pwd-changed-handler! terminal-set-bell-handler!
                 terminal-set-semantic-prompt-handler! semantic-prompt-event-kind
                 semantic-prompt-event-prompt-kind semantic-prompt-event-exit-code semantic-prompt-event-command
                 terminal-set-desktop-notification-handler! desktop-notification-title desktop-notification-body
                 terminal-set-progress-handler! progress-report-state progress-report-progress
                 terminal-set-program-status-handler! program-status-state program-status-kind
                 program-status-progress program-status-id program-status-app program-status-title
                 program-status-message
                 terminal-set-reset-handler!
                 terminal-set-unknown-sequence-handler! terminal-set-unknown-max-bytes!
                 unknown-sequence-tag unknown-sequence-content unknown-sequence-truncated? unknown-sequence-terminator
                 terminal-copy-changed-rows! terminal-copy-rows
                 row-changes-numbering row-changes-rows row-changes-frozen-start row-changes-frozen-end
                 row-changes-cursor row-changes-held?
                 row-numbering-screen row-numbering-generation row-numbering-first-row row-numbering-total-rows
                 row-numbering-rows
                 row-cursor-row row-cursor-x row-cursor-visible? row-cursor-style row-cursor-blinking?
                 styled-row-number styled-row-wrap? terminal-render-held? terminal-end-render-hold!
                 make-key-encoder key-encoder-encode paste-encode paste-safe? terminal-mode-enabled? terminal-modes
                 terminal-set-clipboard-write-handler! clipboard-write-contents
                 terminal-mouse-tracking? terminal-row-numbering row-numbering-active-row
                 make-mouse-encoder mouse-encoder-size mouse-encoder-set-size! mouse-encoder-set-any-button-pressed!
                 mouse-encoder-encode mouse-event
                 clipboard-content-mime clipboard-content-data)
        (rename-in (only-in :gerbil-libghostty/ghostty key-event terminal)
                   (key-event ghostty-key-event) (terminal vt-terminal))
        ./protocol
        ./io
        ./connection
        ./keys
        ./screen
        ./copy-text
        ./links)
(export terminals
        terminal-shell
        terminal-term
        terminal-environment
        terminal-max-scrollback
        terminal-timer-delay
        terminal-adaptive-fps
        terminal-immediate-redraw-interval
        terminal-plain-link-detection-delay
        terminal-input-buffer-size
        terminal-buffer-name
        terminal-buffer-name-function
        terminal-kill-buffer-on-exit
        terminal-query-before-killing
        terminal-initial-input-mode
        terminal-scroll-on-input
        terminal-ignore-cursor-change
        terminal-colors
        terminal-status-line-format
        terminal-enable-osc52
        terminal-paste-protection
        terminal-confirm-close-tab
        terminal-enable-url-detection
        terminal-enable-file-detection
        terminal-readonly-fast-exit
        terminal-line-mode-history-size
        terminal-mark-activation-input-mode
        terminal-mouse-drag-input-mode
        terminal-prompt-navigation-input-mode
        terminal-unknown-sequence-max-bytes
        terminal-shell-integration
        terminal-shell-integration-title
        shell-integration
        parse-directory-report
        unknown-sequence-number
        parse-colors-report
        status-line-format
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
  "Seconds between redraws of a terminal under sustained output (about 30 per second; ghostel-timer-delay).")
(defsetting terminal-adaptive-fps #t
  "Whether the first output after a quiet spell (100 ms) is drawn after at most 16 ms rather than terminal-timer-delay (ghostel-adaptive-fps).")
(defsetting terminal-immediate-redraw-interval 0.05
  "Seconds after a key within which a terminal's output is drawn at once, as its echo (ghostel-immediate-redraw-interval).")
(defsetting terminal-plain-link-detection-delay 0.1
  "Seconds after a redraw before its rows are searched for plain URLs and file references; redraws within the delay share one search, and 0 searches at each redraw (ghostel-plain-link-detection-delay).")
(defsetting terminal-input-buffer-size (* 1024 1024)
  "Bytes of a terminal's output Tuna holds before it has parsed them; past this it stops reading, and the helper and then the program wait, so a flood never outruns the editor.")
(defsetting terminal-buffer-name "*terminal*"
  "The name of terminal buffers; later ones get <2>, <3>, ...")
(defsetting terminal-buffer-name-function #f
  "How a terminal's buffer is renamed as its program reports: #f never, 'title \"*terminal: TITLE*\", 'directory \"*terminal: FOLDER*\".")
(defsetting terminal-kill-buffer-on-exit #t
  "Whether a terminal's buffer is killed when its program ends.")
(defsetting terminal-query-before-killing 'auto
  "Whether killing a terminal's buffer asks first: #t while its program runs, #f never, 'auto while a command runs in it.")
(defsetting terminal-initial-input-mode 'semi-char
  "The input mode a new terminal starts in: 'semi-char, 'char, or 'line (from its first prompt).")
(defsetting terminal-line-mode-history-size 200
  "How many lines line mode remembers for M-p and M-n (ghostel-line-mode-history-size).")
(defsetting terminal-scroll-on-input #t
  "Whether typing in a terminal scrolled up brings its views back to the bottom.")
(defsetting terminal-ignore-cursor-change #f
  "Whether a terminal ignores its program's cursor style and draws a block cursor.")
(defsetting terminal-readonly-fast-exit #t
  "Whether copy mode ends at q, C-g or any key that types, which then goes to the program (ghostel-readonly-fast-exit). Off, copy mode ends only with C-c C-t or another input mode.")
(defsetting terminal-mark-activation-input-mode 'default
  "What setting the mark (C-SPC) in semi-char mode does (ghostel-mark-activation-input-mode): 'default or 'copy enters copy mode with the mark at the cursor; #f leaves C-SPC to the program.")
(defsetting terminal-mouse-drag-input-mode 'default
  "What a left click or drag in a terminal in semi-char mode does when its program does not take the mouse (ghostel-mouse-drag-input-mode): 'default or 'copy enters copy mode with point at the click, or the region dragged over; #f does nothing, leaving the browser's own selection.")
(defsetting terminal-prompt-navigation-input-mode 'default
  "What prompt navigation (C-c M-n, C-c M-p, from a shell's OSC 133 marks) does outside copy mode (ghostel-prompt-navigation-input-mode): 'default or 'copy enters copy mode and moves point to the prompt; #f scrolls the views to it, staying in the mode.")
(defsetting terminal-unknown-sequence-max-bytes 4096
  "How many bytes of an OSC or APC sequence the terminal does not know reach terminal-unknown-sequence-hook; longer ones arrive cut. #f sends none.")
(defsetting terminal-shell-integration #t
  "Whether a terminal's shell (bash, zsh or fish) starts with Tuna's shell integration, which reports its folder (OSC 7) and marks its prompts and commands (OSC 133), without changes to its startup files (ghostel-shell-integration).")
(defsetting terminal-shell-integration-title #t
  "Whether Tuna's bash and zsh integration set the title, to the folder at the prompt and the command while it runs, as Ghostty's title feature does (fish sets its own). ghostel's integration leaves the title to the shell.")
(defsetting terminal-confirm-close-tab #t
  "Whether closing a plain browser tab asks first while its selected view shows a terminal whose program runs, since C-w and other keys close tabs there. An installed app is never asked.")
(defsetting terminal-enable-url-detection #t
  "Whether plain http(s) URLs in a terminal's output are links (ghostel-enable-url-detection).")
(defsetting terminal-enable-file-detection #t
  "Whether FILE:LINE[:COLUMN] references to files that exist, in a terminal's output, are links that open the file there (ghostel-enable-file-detection).")
(defsetting terminal-enable-osc52 #f
  "Whether programs may copy text to the kill ring and the browser's clipboard (OSC 52). Off, as in ghostel: any output, a file you cat included, could replace what you are about to paste. Programs never read the clipboard.")
(defsetting terminal-paste-protection #f
  "Whether pasting text that could run commands (a newline, or the end of a bracketed paste) into a program that did not ask for bracketed paste asks first, as Ghostty's clipboard-paste-protection does. Off, as in ghostel.")
(defsetting terminal-colors #f
  "The colours a terminal answers programs' colour queries with (OSC 4, 10, 11, 12, the light or dark report): #f for the theme's, as the browser draws them, or an alist of foreground, background, cursor (\"#rrggbb\") and palette (a list of them) whose entries win over the theme's.")
(defsetting terminal-status-line-format "(%.30t)"
  "What a terminal shows in its status line after the buffer's name (ghostel-buffer-identification-format): %t its title, %d its folder, %.Nt or %.Nd at most N characters of them, %% a %; nothing when it names the title and there is none. #f shows nothing.")

;;; State

;; While in line mode: the input, a text in TEXT-NODE, under WRAPPER (a
;; terminal-line-input node shown after the cursor's row, over the rest of
;; it); the lines sent, newest first, and which one M-p and M-n show.
(defclass line-state ((text-node : node)
                      (wrapper   : node)
                      (history   : :list)
                      (index     :? :fixnum))
  final: #t)

;; While in copy mode: the frozen copy of the rows (COPY, in the text
;; node TEXT-NODE), the number of its first row, and the input mode to go back
;; to.
(defclass copy-state ((text-node : node)
                      (copy     : copy-text)
                      (first    : :integer)
                      (previous : :symbol)
                      (prompts  : :list))    ; (ROW . INDEX) where prompts start, ascending
  final: #t)

(defclass (live-terminal terminal)
  ((socket       : :string)
   (link         :? connection)       ; to its helper, once connected
   (reader       :? job)
   (mirror       :? vt-terminal)        ; libghostty terminal, from the helper's snapshot
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
   (link-timer   :? :t)            ; its timer for finding links in rows copied
   (fill-timer   :? :t)            ; its timer for copying older rows once output pauses
   (arrived      : :real)          ; when output last arrived
   (scheduled?   : :boolean)       ; the redraw timer runs
   (sync-due?    : :boolean)       ; output not yet drawn, maybe until a view shows it
   (inbox        :? frame-inbox)         ; what its reader read and the editor has not taken
   (held-since   :? :real)
   (running?     : :boolean)            ; a command runs, by OSC 133
   (started      :? :real)              ; when that command started (OSC 133 C)
   (failure      :? :string)            ; the last failure reported
   (refusals     : :fixnum)
   (last-client  :? :t)                 ; the client that last typed into it
   (copy         :? copy-state)         ; while in copy mode
   (line         :? line-state)         ; while in line mode
   (line-paused? : :boolean)            ; line mode waits for the alternate screen to end
   (history      : :list)               ; line mode's lines sent, newest first
   (status       : source))             ; changes with what its status line shows
  final: #t)

(defclass terminals-state ((ctx       : context)
                           (terms     : HashTable)        ; id -> live-terminal
                           (by-buffer : HashTable)        ; buffer -> live-terminal
                           (semi-char : entry-table)
                           (char-map  : entry-table)
                           (quote-map : entry-table)
                           (copy-map  : entry-table)      ; copy mode
                           (copy-fast-map : entry-table)  ; copy mode with fast exit
                           (line-map  : entry-table)      ; line mode's input
                           (line-root-map : entry-table)  ; line mode, around the input
                           (jobs      : job-group)
                           (encoder   : :t)
                           (mouse-encoder : :t)
                           (sizes     : HashTable)        ; client -> list of measured views
                           (quoting   : :list)            ; prompts waiting for a key, newest first
                           (poster    :? :procedure)
                           (focused   :? live-terminal)
                           (yank      : :fixnum)
                           (waiting   : :list)            ; terminals to connect once the loop runs
                           (owed      : :list)            ; terminals whose output waits for a view
                           (colors    :? theme-colors) ; the theme's, as a browser last measured them
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

;; ENTRIES, "NAME=value" strings, the first for each name kept, a bare
;; "NAME" removing it.
(def (first-entries (entries : :list)) => :list
  (let (seen (make-hash-table))
    (filter-map (lambda ((entry : :string))
                  (let* ((equals (string-index entry #\=))
                         (name (if equals (substring entry 0 equals) entry)))
                    (and (not (hash-get seen name))
                         (begin (hash-put! seen name #t) equals)
                         entry)))
                entries)))

;; The value of NAME in ENVIRONMENT, "NAME=value" strings, or #f.
(def (environment-value (environment : :list) (name : :string)) => (Maybe :string)
  (let* ((prefix (string-append name "="))
         (entry (find (cut string-prefix? prefix <>) environment)))
    (and entry (substring entry (string-length prefix) (string-length entry)))))

;; The shell PROGRAM (a path and its arguments) with Tuna's shell
;; integration, from the scripts in DIRECTORY, as ghostel injects its own
;; (ghostel--setup-local-integration), given the ENVIRONMENT it would
;; have: (PROGRAM . ENTRIES), the entries to put before that environment.
;; bash runs in POSIX mode, which reads ENV, naming a file that leaves it
;; and reads the startup files; zsh gets a ZDOTDIR whose .zshenv gives
;; ZDOTDIR back; fish finds a vendor configuration file through
;; XDG_DATA_DIRS. Any other program, or a missing script, is left alone.
(def (shell-integration (program : :list) (directory : :string) (environment : :list) (title? : :boolean))
  => :pair
  (let* ((shell (path-strip-directory (car program)))
         (common [(string-append "TUNA_SHELL_INTEGRATION_DIR=" directory)
                  (string-append "TUNA_SHELL_FEATURES=" (if title? "title" ""))])
         (bootstrap (path-expand "bootstrap" directory))
         (old (lambda ((name : :string) (saved : :string))
                (let (value (environment-value environment name))
                  (if value [(string-append saved "=" value)] [])))))
    (cond
     ((and (string-contains shell "bash") (file-exists? (path-expand "bash/inject.bash" bootstrap)))
      (cons (cons* (car program) "--posix" (cdr program))
            (append [(string-append "ENV=" (path-expand "bash/inject.bash" bootstrap))
                     (string-append "TUNA_BASH_INJECT=1 " (string-join (cdr program) " "))]
                    (old "ENV" "TUNA_BASH_ENV")
                    (if (environment-value environment "HISTFILE")
                      []
                      [(string-append "HISTFILE=" (path-expand ".bash_history" (or (environment-value environment "HOME") "~")))
                       "TUNA_BASH_UNEXPORT_HISTFILE=1"])
                    common)))
     ((and (string-contains shell "zsh") (file-exists? (path-expand "zsh/.zshenv" bootstrap)))
      (cons program
            (append [(string-append "ZDOTDIR=" (path-expand "zsh" bootstrap))]
                    (old "ZDOTDIR" "TUNA_ZSH_ZDOTDIR")
                    common)))
     ((and (string-contains shell "fish")
           (file-exists? (path-expand "fish/vendor_conf.d/tuna-shell-integration.fish" bootstrap)))
      (cons program
            (cons* (string-append "XDG_DATA_DIRS=" bootstrap ":"
                                  (or (environment-value environment "XDG_DATA_DIRS") "/usr/local/share:/usr/share"))
                   (string-append "TUNA_SHELL_INTEGRATION_XDG_DIR=" bootstrap)
                   common)))
     (else (cons program [])))))

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
                          [(string-append "PWD=" directory)] base)))
    (first-entries entries)))

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
                              link-timer: #f fill-timer: #f arrived: 0 scheduled?: #f inbox: #f sync-due?: #f held-since: #f running?: #f started: #f failure: #f refusals: 0 last-client: #f copy: #f line: #f line-paused?: #f history: []
                              status: (new-source))))
    (add-buffer! b)
    (hash-put! self.terms id term)
    (hash-put! self.by-buffer b term)
    (set! (live-terminal-timer term)
      (context-run-with-timer! self.ctx (setting-value terminal-timer-delay) #f
                               (lambda ()
                                 (set! (live-terminal-scheduled? term) #f)
                                 (when (live-terminal-sync-due? term)
                                   (if (shown? term)
                                     (guarded! term "redraw" (lambda () (sync! self term)))
                                     (owe! self term))))
                               name: 'terminal-redraw))
    (set! (live-terminal-link-timer term)
      (context-run-with-timer! self.ctx (setting-value terminal-plain-link-detection-delay) #f
                               (lambda () (guarded! term "link detection" (lambda () (scan-links! term))))
                               name: 'terminal-links))
    (set! (live-terminal-fill-timer term)
      (context-run-with-timer! self.ctx (setting-value terminal-timer-delay) #f
                               (lambda () (guarded! term "redraw" (lambda () (fill-when-quiet! term))))
                               name: 'terminal-fill))
    term))

;; The terminal the current buffer shows, or #f.
(def (current-terminal (self : terminals-state)) => (Maybe live-terminal)
  (hash-get self.by-buffer (current-buffer)))

(def (views-showing (term : live-terminal)) => :list
  (if (service-there? layout-service)
    (filter (lambda ((v : view)) (eq? (view-showing v) (terminal-buffer term))) (view-list))
    ;; Without a layout, the buffers service's one view.
    (let (v (selected-view))
      (if (eq? (view-showing v) (terminal-buffer term)) [v] []))))

;; Start the job reading TERM's helper: it starts the helper with LAUNCH
;; first when one is given, waits for its socket, connects, and posts the
;; connection, then every batch of frames, and ends with 'ended.
(def (start-reader! (self : terminals-state) (term : live-terminal) (launch :? helper-launch)) => :void
  (if (editor-loop-running?)
    (let (inbox (new-frame-inbox (setting-value terminal-input-buffer-size)))
      (keep-poster! self)
      (let (old term.inbox) (when old (frame-inbox-close! old)))
      (set! term.inbox inbox)
      (set! term.reader
        (job-group-start! self.jobs (terminal-id term)
                          input: [launch term.socket inbox]
                          run: reader-run
                          apply: (lambda (result) (receive! self term inbox result)))))
    ;; Restored at start, before the editor loop runs jobs: connect once
    ;; the first task runs.
    (set! self.waiting (cons term self.waiting))))

;; On the job's thread. Its input and posts are a helper launch, a
;; connection and the inbox frames wait in: not editor state, so they may
;; cross threads, though they are not plain data. It posts 'frames when
;; the inbox has frames and was empty, and waits while it is full.
(def (reader-run (input : :list) (cancelled? : :procedure) (post! : :procedure)) => :t
  (let ((launch (car input))
        (socket (cadr input))
        (inbox (caddr input)))
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
                 (when (frame-inbox-put! inbox frames) (post! 'frames))
                 (unless (cancelled?) (lp)))))
           'ended))))))

(def (error-message (e : :t)) => :string
  (let (text (and (error-object? e) (error-object-message e)))
    (if (string? text) text "error")))

(def (send! (term : live-terminal) (type : :symbol) (payload : :u8vector := (u8vector))) => :void
  (let (c term.link)
    (when c (connection-send! c type payload))))

;;; What the helper sends

(def (receive! (self : terminals-state) (term : live-terminal) (waiting : frame-inbox) (result : :t)) => :void
  (keep-poster! self)
  (when (and (eq? (hash-get self.terms (terminal-id term)) term) (not self.stopping?))
    (cond
     ((and (pair? result) (eq? (car result) 'connected))
      (set! term.link (cdr result)))
     ((eq? result 'frames)
      (for-each (lambda ((f : frame)) (guarded! term "output" (lambda () (receive-frame! self term f))))
                (frame-inbox-take! waiting)))
     ((and (pair? result) (eq? (car result) 'failed))
      (message (string-append (terminal-id-name term) ": " (cdr result)))
      (helper-gone! self term))
     ((memq result '(ended gone))
      (set! term.link #f)
      ;; A connection the helper refused as busy ends too; another try
      ;; follows.
      (unless (or (terminal-exit-status term) (fx> term.refusals 0))
        (helper-gone! self term))))))

;; Run THUNK, WHAT for TERM, reporting a failure as the kernel reports a
;; failing hook, in the echo area and Tuna's log, once while it repeats,
;; and carrying on: the next output and redraw still happen.
(def (guarded! (term : live-terminal) (what : :string) (thunk : :procedure)) => :void
  (with-catch
   (lambda (e)
     (if (quit-condition? e)
       (raise e)
       (let (report (string-append "Terminal " (terminal-id-name term) ": " what " failed: " (exception-summary e)))
         (unless (equal? report term.failure)
           (set! term.failure report)
           (let (port (current-error-port))
             (display report port)
             (newline port))
           (message report)))))
   thunk))

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
             (send-colors! self term)
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
           (set! term.arrived (now))
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
    ;; OSC 52 copies: the reply is the policy answer, the copy itself waits.
    (terminal-set-clipboard-write-handler!
     mirror
     (lambda (request)
       (if (buffer-local-value terminal-enable-osc52 (terminal-buffer term))
         (let (text (clipboard-text request))
           (when text (push-effect! term (cons 'copy text)))
           'success)
         'denied)))
    (terminal-set-semantic-prompt-handler! mirror (lambda (event) (push-effect! term (cons 'prompt event))))
    (terminal-set-desktop-notification-handler! mirror (lambda (n) (push-effect! term (cons 'notification n))))
    (terminal-set-progress-handler! mirror (lambda (report) (push-effect! term (cons 'progress report))))
    ;; The helper answers the program's OSC 7501 query; this only listens.
    (terminal-set-program-status-handler! mirror (lambda (report) (push-effect! term (cons 'status report))))
    (terminal-set-reset-handler! mirror (lambda () (push-effect! term '(reset))))
    (let (limit (setting-value terminal-unknown-sequence-max-bytes))
      (when (and (fixnum? limit) (fx> limit 0))
        (terminal-set-unknown-max-bytes! mirror limit)
        (terminal-set-unknown-sequence-handler! mirror (lambda (sequence) (push-effect! term (cons 'unknown sequence))))))
    (set! term.mirror mirror)
    ;; A new mirror numbers its rows anew: every row is copied again.
    (set! (row-store-generation term.primary) #f)
    (set! (row-store-generation term.alternate) #f)
    (if (shown? term) (sync! self term) (begin (set! term.sync-due? #t) (owe! self term)))))

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
         ((copy) (program-copied! self term (cdr effect)))
         ((prompt) (shell-reported! self term (cdr effect)))
         ((notification)
          (let (n (cdr effect))
            (run-hook-safely terminal-notification-hook term
                             (lenient-utf8 (desktop-notification-title n)) (lenient-utf8 (desktop-notification-body n)))))
         ((progress)
          (let (report (cdr effect))
            (run-hook-safely terminal-progress-hook term (progress-report-state report) (progress-report-progress report))))
         ((status) (program-status-reported! term (cdr effect)))
         ((reset) (run-hook-safely terminal-reset-hook term))
         ((unknown)
          (let* ((sequence (cdr effect))
                 (content (lenient-utf8 (unknown-sequence-content sequence)))
                 (kind (unknown-sequence-tag sequence)))
            (run-hook-safely terminal-unknown-sequence-hook term kind
                             (and (eq? kind 'osc) (unknown-sequence-number content))
                             content (unknown-sequence-truncated? sequence) (unknown-sequence-terminator sequence))))
         (else (void))))
     effects)))

;; A shell integration event (OSC 133), EVENT: whether a command runs,
;; when it started, and the hooks.
(def (shell-reported! (self : terminals-state) (term : live-terminal) (event : :t)) => :void
  (case (semantic-prompt-event-kind event)
    ((prompt-start)
     ;; No D comes for a command that replaced the shell (exec zsh).
     (set! term.running? #f)
     (set! term.started #f)
     (run-hook-safely terminal-prompt-hook term (semantic-prompt-event-prompt-kind event)))
    ((output-start)
     (set! term.running? #t)
     (set! term.started (now))
     (let (command (lenient-utf8 (semantic-prompt-event-command event)))
       (run-hook-safely terminal-command-start-hook term (and (not (string-empty? command)) command))))
    ((command-end)
     (let (started term.started)
       (set! term.running? #f)
       (set! term.started #f)
       (run-hook-safely terminal-command-finish-hook term (semantic-prompt-event-exit-code event)
                        (and started (- (now) started)))))
    (else (void))))

;; An OSC 7501 REPORT, checked by libghostty: a record cleared ("" for
;; all), or reported.
(def (program-status-reported! (term : live-terminal) (report : :t)) => :void
  (def (text (bytes : :u8vector)) => (Maybe :string)
    (and (fx> (u8vector-length bytes) 0) (lenient-utf8 bytes)))
  (let ((id (lenient-utf8 (program-status-id report)))
        (state (program-status-state report)))
    (if (eq? state 'clear)
      (run-hook-safely terminal-program-status-clear-hook term id)
      (run-hook-safely terminal-program-status-hook term
                       (make-program-status-report id state (program-status-kind report) (program-status-progress report)
                                                   (text (program-status-app report)) (text (program-status-title report))
                                                   (text (program-status-message report)))))))

;; The number an OSC sequence's CONTENT starts with, before its first ;,
;; or #f.
(def (unknown-sequence-number (content : :string)) => (Maybe :fixnum)
  (let* ((end (or (string-index content #\;) (string-length content)))
         (n (and (fx> end 0) (string->number (substring content 0 end) 10))))
    (and (fixnum? n) (fx>= n 0) n)))

(def (lenient-utf8 (bytes : :u8vector)) => :string
  (:- (with-catch (lambda (e) (list->string (map integer->char (u8vector->list bytes))))
                  (lambda () (utf8->string bytes)))
      :string))

(def (run-hook-safely (hook : :t) . args) => :void
  (with-catch (lambda (e) (message (string-append "Terminal hook failed: " (error-message e))))
              (lambda () (apply run-hook hook args))))

;;; OSC 52

;; The text an OSC 52 write carries, or #f to clear or for nothing to copy.
(def (clipboard-text (request : :t)) => (Maybe :string)
  (let* ((contents (vector->list (clipboard-write-contents request)))
         (text (or (find (lambda (c) (string-prefix? "text/plain" (lenient-utf8 (clipboard-content-mime c)))) contents)
                   (and (pair? contents) (car contents)))))
    (and text (fx> (u8vector-length (clipboard-content-data text)) 0)
         (lenient-utf8 (clipboard-content-data text)))))

;; TERM's program copied TEXT (OSC 52): onto the kill ring, and the
;; browser's clipboard through the tab that last typed into TERM, as
;; ghostel puts it on the kill ring and the system clipboard. Best effort:
;; a browser may refuse a write no key or click came just before, and the
;; web transport then says so.
(def (program-copied! (self : terminals-state) (term : live-terminal) (text : :string)) => :void
  (when (service-there? editing-service)
    (parameterize ((current-client term.last-client))
      (kill-new text))))

;;; Links

;; Open URI, a link in TERM, as ghostel does (ghostel--open-link): a file
;; (file://, fileref: or a path, with :LINE[:COLUMN]) in its buffer, in
;; another view, at that line; a web address in a new browser tab, through
;; the tab that asked (or last typed into TERM), since Tuna has no
;; browse-url of its own.
(def (open-link! (self : terminals-state) (term : live-terminal) (uri : :string)) => :void
  (let* ((directory (or (terminal-directory term) (buffer-default-directory (terminal-buffer term))))
         (file (link-file-target uri directory (host-name))))
    (cond
     ((web-link? uri)
      (let (c (or (current-client) term.last-client))
        (if (and c (service-there? page-service))
          (page-instruct! c "terminalOpen" uri)
          (message (string-append "No browser tab to open " uri " in")))))
     ((and file (service-there? files-service) (file-exists? (car file)))
      (let* ((b (find-file-noselect (car file)))
             (v (if (service-there? layout-service) (display-buffer b) (selected-view))))
        (when (service-there? layout-service) (select-view v))
        (unless (service-there? layout-service) (switch-to-buffer b))
        (let (line (cadr file))
          (when line
            (let (t (current-text))
              (goto-char (text-position-at t (fxmax 1 (fxmin line (text-line-count t)))
                                           (fxmax 0 (fx1- (or (caddr file) 1))))))))))
     (else (message (string-append "Cannot open " uri))))))

;; The link a page script says was clicked in the terminal ID: open it
;; (open-link! opens only web addresses and files that exist).
(def (link-clicked! (self : terminals-state) (c : :t) (id : :string) (uri : :string)) => :void
  (let (term (hash-get self.terms id))
    (when term
      (parameterize ((current-client c))
        (open-link! self term uri)))))

;;; Titles and folders

(def (title-changed! (self : terminals-state) (term : live-terminal) (title : :string)) => :void
  (set! term.title title)
  (source-changed! term.status)
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
        (source-changed! term.status)
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

;; Whether a view shows TERM.
(def (shown? (term : live-terminal)) => :boolean
  (pair? (views-showing term)))

;; Output arrived (ghostel--invalidate): drawn at once when it is the echo
;; of a key, else by TERM's redraw timer, which coalesces what arrives
;; meanwhile; a terminal no view shows is drawn once one does.
(def (output-arrived! (self : terminals-state) (term : live-terminal)) => :void
  (set! term.sync-due? #t)
  (cond
   ((not (shown? term)) (owe! self term))
   ((< (- (now) term.last-input) (setting-value terminal-immediate-redraw-interval)) (sync! self term))
   (else (schedule-redraw! term))))

;; Start TERM's redraw timer unless it runs: after terminal-timer-delay,
;; or, with terminal-adaptive-fps, after at most 16 ms when nothing was
;; scheduled for 100 ms, so the first frame of a burst comes quickly.
(def (schedule-redraw! (term : live-terminal)) => :void
  (unless term.scheduled?
    (let* ((t (now))
           (delay (setting-value terminal-timer-delay))
           (quiet? (and (setting-value terminal-adaptive-fps) (> (- t term.last-output) 0.1))))
      (set! term.scheduled? #t)
      (set! term.last-output t)
      (restart-timer term.timer seconds: (if quiet? (min 0.016 delay) delay)))))

;; Remember that TERM's output waits for a view to show it: its rows are
;; not copied meanwhile, as ghostel leaves a hidden buffer's redraw
;; pending.
(def (owe! (self : terminals-state) (term : live-terminal)) => :void
  (unless (memq term self.owed)
    (set! self.owed (cons term self.owed))))

;; After each task: draw the terminals whose output waited for a view, now
;; that one shows them (ghostel redraws once a window shows the buffer).
(def (draw-owed! (self : terminals-state)) => :void
  (when (pair? self.owed)
    (let (shown (filter shown? self.owed))
      (when (pair? shown)
        (set! self.owed (filter (lambda (term) (not (memq term shown))) self.owed))
        (for-each schedule-redraw! shown)))))

;; The row nodes of TERM's mirror's screen made current, its root showing
;; that screen, and the views following its output at its bottom.
(def (sync! (self : terminals-state) (term : live-terminal)) => :void
  (set! term.sync-due? #f)
  (let (mirror term.mirror)
    ;; Copy mode freezes the rows; output goes on into the mirror.
    (when (and mirror (not term.copy))
      (let* ((following (filter (cut following? self term <>) (views-showing term)))
             (changes (terminal-copy-changed-rows! mirror))
             (numbering (row-changes-numbering changes))
             (screen (row-numbering-screen numbering))
             (store (if (eq? screen 'alternate) term.alternate term.primary))
             (first (row-numbering-first-row numbering))
             (end (+ first (row-numbering-total-rows numbering)))
             (copied (make-hash-table-eqv))
             (prompts (make-hash-table-eqv))
             (cursor (row-changes-cursor changes)))
        ;; Rows that left the screen since the last redraw, or every row
        ;; of a new generation, are copied now if near the bottom, where a
        ;; view following the output shows them; older ones once output
        ;; pauses, so a flood does not copy rows it trims before anyone
        ;; sees them.
        (let (copy-or-defer!
              (lambda (from to)
                (let (recent (max from (- end (* recent-screens (row-numbering-rows numbering)))))
                  (let lp ((n from))
                    (when (< n recent) (hash-put! (row-store-unfilled store) n #t) (lp (+ n 1))))
                  (when (< recent to) (copy-rows! copied prompts mirror recent to)))))
          (if (eqv? (row-store-generation store) (row-numbering-generation numbering))
            (begin
              (row-store-trim! store first)
              (row-store-extend! store end)
              (let ((from (max first (row-changes-frozen-start changes)))
                    (to (min end (row-changes-frozen-end changes))))
                (when (< from to) (copy-or-defer! from to))))
            (begin
              (row-store-reset! store (row-numbering-generation numbering) first)
              (row-store-extend! store end)
              (copy-or-defer! first end))))
        (vector-for-each (cut keep-row! copied prompts <>) (row-changes-rows changes))
        (fill-near-views! term store mirror copied prompts)
        (set-rows! term store copied)
        (hash-for-each (lambda (number prompt)
                         (let (n (row-store-row store number))
                           (when n (set-node-attribute! n 'prompt prompt))))
                       prompts)
        (move-cursor! term store cursor)
        (let (blocks (row-store-blocks store))
          (unless (and (eq? screen term.screen) (equal? (map node-id blocks) (map node-id (node-children term.root))))
            (set-node-attribute! term.root 'screen screen)
            (set-node-children! term.root blocks)))
        ;; Once the rows are the root's, so a view can focus the input.
        (follow-line-mode! self term screen)
        (set! term.screen screen)
        (when (fx> (hash-length copied) 0) (links-due! term))
        (when (fx> (hash-length (row-store-unfilled store)) 0) (restart-timer term.fill-timer))
        (refresh-root-attributes! self term)
        (end-long-hold! term mirror)
        (for-each (cut place-at-bottom! term <>) following)))))

;; How many screens of rows above the bottom a redraw copies at once; older
;; rows wait until output pauses.
(def recent-screens 4)

;; How many waiting rows are copied in one go once output pauses.
(def fill-batch 1000)

;; Copy the waiting rows near where views that do not follow the output
;; show TERM, two screens either way, into COPIED and PROMPTS.
(def (fill-near-views! (term : live-terminal) (store : row-store) (mirror : vt-terminal)
                       (copied : HashTable) (prompts : HashTable))
  => :void
  (let (unfilled (row-store-unfilled store))
    (when (fx> (hash-length unfilled) 0)
      (for-each
       (lambda ((v : view))
         (let* ((target (placement-target (view-placement v)))
                (top (and target (node-attribute (item-node target) 'number))))
           (when (integer? top)
             (let ((reach (* 2 (max 1 term.rows))))
               (copy-unfilled! store mirror copied prompts
                               (filter (lambda (n) (<= (- top reach) n (+ top reach reach)))
                                       (hash-keys unfilled)))))))
       (views-showing term)))))

;; Copy the rows NUMBERS, waiting in STORE, from MIRROR into COPIED and
;; PROMPTS.
(def (copy-unfilled! (store : row-store) (mirror : vt-terminal) (copied : HashTable) (prompts : HashTable)
                     (numbers : :list))
  => :void
  (let lp ((numbers (list-sort < numbers)))
    (match numbers
      ([] (void))
      ([n . more]
       ;; A run of consecutive numbers at a time.
       (let run ((last n) (rest more))
         (if (and (pair? rest) (= (car rest) (+ last 1)))
           (run (car rest) (cdr rest))
           (begin
             (copy-rows! copied prompts mirror n (+ last 1))
             (let mark ((m n)) (when (<= m last) (hash-remove! (row-store-unfilled store) m) (mark (+ m 1))))
             (lp rest))))))))

;; Once output has paused for terminal-timer-delay, copy TERM's waiting
;; rows, the newest first, fill-batch at a time; while output goes on, or
;; no view shows TERM, wait (a redraw starts the timer again).
(def (fill-when-quiet! (term : live-terminal)) => :void
  (let ((mirror term.mirror)
        (store (current-store term)))
    (when (and mirror (not term.copy) (fx> (hash-length (row-store-unfilled store)) 0) (shown? term))
      (if (< (- (now) term.arrived) (setting-value terminal-timer-delay))
        (restart-timer term.fill-timer)
        (let ((numbers (list-sort > (hash-keys (row-store-unfilled store))))
              (copied (make-hash-table-eqv))
              (prompts (make-hash-table-eqv)))
          (copy-unfilled! store mirror copied prompts
                          (let take ((ns numbers) (k 0) (out []))
                            (if (or (null? ns) (fx= k fill-batch)) out (take (cdr ns) (fx1+ k) (cons (car ns) out)))))
          (set-copied-rows! term store copied prompts)
          (when (fx> (hash-length (row-store-unfilled store)) 0) (restart-timer term.fill-timer)))))))

;; Copy every row of TERM's screen still waiting, before reading them all.
(def (fill-all-rows! (term : live-terminal)) => :void
  (let ((mirror term.mirror)
        (store (current-store term)))
    (when (and mirror (fx> (hash-length (row-store-unfilled store)) 0))
      (let ((copied (make-hash-table-eqv))
            (prompts (make-hash-table-eqv)))
        (copy-unfilled! store mirror copied prompts (hash-keys (row-store-unfilled store)))
        (set-copied-rows! term store copied prompts)))))

;; Set rows COPIED and their PROMPTS marks on STORE's nodes.
(def (set-copied-rows! (term : live-terminal) (store : row-store) (copied : HashTable) (prompts : HashTable)) => :void
  (set-rows! term store copied)
  (hash-for-each (lambda (number prompt)
                   (let (n (row-store-row store number))
                     (when n (set-node-attribute! n 'prompt prompt))))
                 prompts)
  (when (fx> (hash-length copied) 0) (links-due! term)))

;; Copy rows FROM to TO of MIRROR into COPIED and PROMPTS, a thousand at
;; a time.
(def (copy-rows! (copied : HashTable) (prompts : HashTable) (mirror : vt-terminal) (from : :integer) (to : :integer))
  => :void
  (let lp ((from from))
    (when (< from to)
      (let (upto (min to (+ from 1000)))
        (vector-for-each (cut keep-row! copied prompts <>) (terminal-copy-rows mirror from upto))
        (lp upto)))))

;; Keep ROW, a styled row, in COPIED, its number -> (RUNS . WRAP?), and
;; PROMPTS, its number -> its prompt mark (row-prompt-mark).
(def (keep-row! (copied : HashTable) (prompts : HashTable) (row : :t)) => :void
  (hash-put! copied (styled-row-number row) (cons (row-runs row) (styled-row-wrap? row)))
  (hash-put! prompts (styled-row-number row) (row-prompt-mark row)))

;; Set the rows COPIED holds on their nodes in STORE, each attribute
;; once, and note them to be searched for plain links (ghostel-links)
;; once terminal-plain-link-detection-delay has passed, as ghostel does:
;; the redraws meanwhile share one search, and rows a flood trimmed by
;; then are never searched.
(def (set-rows! (term : live-terminal) (store : row-store) (copied : HashTable)) => :void
  (let* ((b (terminal-buffer term))
         (search? (or (buffer-local-value terminal-enable-url-detection b)
                      (buffer-local-value terminal-enable-file-detection b))))
    (hash-for-each (lambda (number (row : :pair))
                     (let (n (row-store-row store number))
                       (when n
                         (set-node-attribute! n 'runs (car row))
                         (set-node-attribute! n 'wrap (cdr row))
                         (when search? (hash-put! (row-store-unscanned store) number #t)))))
                   copied)))

;; Look for links in the rows copied, after terminal-plain-link-detection-delay.
(def (links-due! (term : live-terminal)) => :void
  (let (delay (setting-value terminal-plain-link-detection-delay))
    (if (and (real? delay) (> delay 0))
      (restart-timer term.link-timer seconds: delay)
      (scan-links! term))))

;; Put the plain links found in the program's lines that rows copied
;; since the last search are part of, rows it wrapped joined, into those
;; lines' rows; not in the line of the cursor, which is the input being
;; typed (its rows are copied again when the cursor leaves).
(def (scan-links! (term : live-terminal)) => :void
  (let* ((b (terminal-buffer term))
         (urls? (buffer-local-value terminal-enable-url-detection b))
         (files? (buffer-local-value terminal-enable-file-detection b))
         (directory (or (terminal-directory term) (buffer-default-directory b)))
         (cursor (let (row term.cursor-row) (and row (node-attribute row 'number))))
         (exists (make-hash-table)))
    (for-each
     (lambda ((store : row-store))
       (let ((numbers (hash-keys (row-store-unscanned store)))
             (seen (make-hash-table-eqv))
             (final (make-hash-table-eqv)))
         (hash-clear! (row-store-unscanned store))
         (def (row-of (number : :integer)) => (Maybe :pair)
           (or (hash-get final number)
               (let (n (row-store-row store number))
                 (and n (cons (node-attribute n 'runs) (node-attribute n 'wrap))))))
         (def (resolve (path : :string)) => (Maybe :string)
           (let (absolute (if (string-prefix? "/" path) path (path-expand path directory)))
             (let (known (hash-ref exists absolute 'unknown))
               (if (eq? known 'unknown)
                 (let (there (and (file-exists? absolute) absolute))
                   (hash-put! exists absolute there)
                   there)
                 known))))
         (when (or urls? files?)
           (for-each
            (lambda (number)
              (unless (or (hash-get seen number) (not (row-store-row store number)))
                (let* ((start (let back ((m number) (k 0))
                                (let (previous (row-of (- m 1)))
                                  (if (and previous (cdr previous) (< k link-line-rows)) (back (- m 1) (+ k 1)) m))))
                       (end (let forward ((m number) (k 0))
                              (let (row (row-of m))
                                (if (and row (cdr row) (row-of (+ m 1)) (< k link-line-rows)) (forward (+ m 1) (+ k 1)) m)))))
                  (let mark ((m start)) (when (<= m end) (hash-put! seen m #t) (mark (+ m 1))))
                  (unless (and cursor (eq? store (current-store term)) (<= start cursor end))
                    (link-line! final row-of start end urls? files? resolve)))))
            numbers))
         (hash-for-each (lambda (number (row : :pair))
                          (let (n (row-store-row store number))
                            (when n (set-node-attribute! n 'runs (car row)))))
                        final)))
     [term.primary term.alternate])))

;; The store TERM's root shows.
(def (current-store (term : live-terminal)) => row-store
  (if (eq? term.screen 'alternate) term.alternate term.primary))

;; How many rows of one line of the program's are joined to find links
;; in (ghostel--soft-wrap-row-limit).
(def link-line-rows 50)

;; Find links in rows START to END, one line of the program's, and put
;; the rows that get any in FINAL.
(def (link-line! (final : HashTable) (row-of : :procedure) (start : :integer) (end : :integer)
                 (urls? : :boolean) (files? : :boolean) (resolve : :procedure))
  => :void
  (let* ((numbers (let lp ((m end) (out [])) (if (< m start) out (lp (- m 1) (cons m out)))))
         (rows (map row-of numbers))
         (texts (map (lambda ((row : :pair)) (row-text (car row))) rows))
         (links (find-links (apply string-append texts) urls? files? resolve)))
    (unless (null? links)
      (let lp ((numbers numbers) (rows rows) (texts texts) (offset 0))
        (match numbers
          ([number . more]
           (let* ((size (string-length (car texts)))
                  (local (filter-map (lambda ((l : :list))
                                       (let ((from (fxmax 0 (fx- (car l) offset)))
                                             (to (fxmin size (fx- (cadr l) offset))))
                                         (and (fx< from to) [from to (caddr l)])))
                                     links)))
             (when (pair? local)
               (let (row (car rows))
                 (hash-put! final number (cons (link-runs (car row) local) (cdr row)))))
             (lp more (cdr rows) (cdr texts) (fx+ offset size))))
          (else (void)))))))

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
(def (end-long-hold! (term : live-terminal) (mirror : vt-terminal)) => :void
  (if (terminal-render-held? mirror)
    (let (since term.held-since)
      (cond
       ((not since) (set! term.held-since (now)) (set! term.sync-due? #t) (schedule-redraw! term))
       ((> (- (now) since) 1.0) (terminal-end-render-hold! mirror) (set! term.held-since #f))
       (else (set! term.sync-due? #t) (schedule-redraw! term))))
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
  ;; Not while copy mode holds the screen still (vterm, ghostel).
  (unless term.copy (resize-to-measured-views! self term)))

(def (resize-to-measured-views! (self : terminals-state) (term : live-terminal)) => :void
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
    (let (c (current-client)) (when c (set! term.last-client c)))
    (when (setting-value terminal-scroll-on-input)
      (for-each (cut place-at-bottom! term <>) (views-showing term)))
    (send! term 'input bytes)
    (run-hook-safely terminal-input-hook term)))

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

;; Send TEXT as a paste through libghostty's paste encoder: bracketed
;; when the program asked for it. With terminal-paste-protection on, text
;; that could run commands in a program that did not ask for bracketed
;; paste is sent only once the user says yes.
(def (paste! (self : terminals-state) (term : live-terminal) (text : :string)) => :void
  (let ((bytes (string->utf8 text))
        (bracketed? (mode-on? term 'bracketed-paste)))
    (when (or bracketed? (paste-safe? bytes)
              (not (buffer-local-value terminal-paste-protection (terminal-buffer term)))
              (not (service-there? minibuffer-service))
              (yes-or-no? "The text to paste could run commands; paste it? "))
      (send-input! self term (paste-encode bytes bracketed?: bracketed?)))))

(def (set-input-mode! (self : terminals-state) (term : live-terminal) (mode : :symbol)) => :void
  (when term.copy (leave-copy-mode! self term))
  (when term.line (leave-line-mode! self term #t))
  (set! term.line-paused? #f)
  (set! term.input-mode mode)
  (source-changed! term.status)
  (refresh-root-attributes! self term)
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

;;; Copy mode


;; The rows of TERM's current screen, each (RUNS . WRAP?), and the number
;; of the first.
(def (screen-rows (term : live-terminal)) => :values
  (fill-all-rows! term)
  (let* ((store (if (eq? term.screen 'alternate) term.alternate term.primary))
         (first (row-store-base store)))
    (values (let lp ((n (- (row-store-end store) 1)) (out []))
              (if (< n first)
                out
                (lp (- n 1)
                    (let (r (row-store-row store n))
                      (cons (cons (node-attribute r 'runs) (node-attribute r 'wrap)) out)))))
            first)))

;; Where each prompt on TERM's current screen has its input, ascending,
;; each (ROW . INDEX): the row, counted from the screen's first, and the
;; index in its text. A prompt is a row marked where one starts and the
;; continuation rows after it; its input is on the first of them holding
;; typed input, else the last with prompt cells, after those (ghostel
;; lands past the prompt on its first line; a prompt such as starship's
;; begins with an empty line).
(def (screen-prompts (term : live-terminal)) => :list
  (fill-all-rows! term)
  (let* ((store (if (eq? term.screen 'alternate) term.alternate term.primary))
         (first (row-store-base store))
         (end (row-store-end store)))
    (def (mark (n : :integer)) => (Maybe :vector)
      (let (r (row-store-row store n))
        (and r (let (m (node-attribute r 'prompt)) (and (vector? m) m)))))
    ;; From row N of a prompt, the first when FIRST?; TARGET is the best
    ;; row so far, (NUMBER . CELL).
    (def (landing (n : :integer) (target :? :pair) (first? : :boolean)) => (Maybe :pair)
      (let (m (and (< n end) (mark n)))
        (if (or (not m) (and (not first?) (not (eq? (vector-ref m 0) 'prompt-continuation))))
          target
          (let ((cell (vector-ref m 1))
                (input? (vector-ref m 2)))
            (cond
             ((and input? cell) (cons n cell))
             (input? (or target (cons n 0)))
             (else (landing (+ n 1) (if cell (cons n cell) target) #f)))))))
    (let lp ((n first) (out []))
      (if (>= n end)
        (reverse out)
        (let (m (mark n))
          (if (and m (eq? (vector-ref m 0) 'prompt))
            (let (target (landing n #f #t))
              (lp (+ n 1)
                  (if target
                    (cons (cons (- (car target) first)
                                (cell->index (node-attribute (row-store-row store (car target)) 'runs) (cdr target)))
                          out)
                    out)))
            (lp (+ n 1) out)))))))

;; Where TERM's cursor is in the copy C of rows from FIRST, or its end.
(def (cursor-copy-position (term : live-terminal) (c : copy-text) (first : :integer)) => :fixnum
  (let* ((row term.cursor-row)
         (cursor (and row (node-attribute row 'cursor))))
    (if (vector? cursor)
      (copy-text-position c (- (node-attribute row 'number) first)
                          (cell->index (node-attribute row 'runs) (vector-ref cursor 0)))
      (fx1+ (string-length (copy-text-text c))))))

;; The position in TERM's copy of character INDEX of row NUMBER, or #f
;; when that row is not in it.
(def (copy-row-position (term : live-terminal) (number :? :integer) (index : :fixnum)) => (Maybe :fixnum)
  (let ((state term.copy))
    (and state (integer? number)
         (let (i (- number (copy-state-first state)))
           (and (fx<= 0 i) (fx< i (vector-length (copy-text-row-starts (copy-state-copy state))))
                (copy-text-position (copy-state-copy state) i index))))))

;; Freeze TERM's screen as a read-only text, which motion, mark and
;; kill-ring commands work over, its rows' palette colours and links as
;; highlights; every view showing TERM shows the same rows as before, with
;; point at the cursor. Output goes on into the mirror; the rows are drawn
;; again when copy mode ends. A text node, not the rows themselves:
;; editing commands work in one focused text node, and a region cannot
;; span nodes.
(def (enter-copy-mode! (self : terminals-state) (term : live-terminal)) => copy-state
  (or term.copy
      (begin
        (when term.line (leave-line-mode! self term #t))
        (sync! self term)
        (scan-links! term)
        (let-values (((rows first) (screen-rows term)))
          (let* ((c (rows->copy-text rows))
                 (t (new-text (copy-text-text c)))
                 (n (new-text-node t))
                 (point (cursor-copy-position term c first))
                 (placements (map (lambda ((v : view)) (cons v (view-placement v))) (views-showing term)))
                 (state (copy-state text-node: n copy: c first: first
                                    previous: (if (eq? term.input-mode 'char) 'char 'semi-char)
                                    prompts: (screen-prompts term))))
            (set-highlights! t 'terminal (copy-text-spans c))
            (set! term.copy state)
            (set! term.input-mode 'copy)
            (source-changed! term.status)
            (set-node-children! term.root [n])
            (refresh-root-attributes! self term)
            (set-node-keymap! term.root (if (buffer-local-value terminal-readonly-fast-exit (terminal-buffer term))
                                          self.copy-fast-map
                                          self.copy-map))
            (set-buffer-setting! (terminal-buffer term) buffer-read-only #t)
            (for-each (lambda ((pair : :pair))
                        (let ((v (car pair))
                              (p (cdr pair)))
                          (set-view-focus! v n point)
                          (place-copy-view! term v p)))
                      placements)
            (message (if (buffer-local-value terminal-readonly-fast-exit (terminal-buffer term))
                       "Copy mode: press any printable key to exit"
                       "Copy mode: C-c C-t or C-c C-j to exit"))
            state)))))

;; Put V back where placement P had it, now that it shows TERM's copy.
(def (place-copy-view! (term : live-terminal) (v : view) (p : placement)) => :void
  (let* ((state term.copy)
         (n (copy-state-text-node state))
         (target (placement-target p))
         (position (and target (copy-row-position term (node-attribute (item-node target) 'number) 0))))
    (if position
      (place-view! v (node-line-item n position) (placement-align p) offset: (placement-offset p))
      (place-view! v (node-line-item n (view-point v)) 'bottom))))

;; Draw TERM's rows again, as they are now, and go back to the input mode
;; before copy mode, the views following the output.
(def (leave-copy-mode! (self : terminals-state) (term : live-terminal)) => :void
  (let (state term.copy)
    (when state
      (let ((b (terminal-buffer term))
            (mode (copy-state-previous state)))
        (set! term.copy #f)
        (set! term.input-mode mode)
        (source-changed! term.status)
        (set-buffer-setting! b buffer-read-only #f)
        (set-node-keymap! term.root (if (eq? mode 'char) self.char-map self.semi-char))
        (for-each (lambda ((v : view)) (reset-view! v b #f 1 0)) (views-showing term))
        (sync! self term)
        (for-each (cut place-at-bottom! term <>) (views-showing term))
        (resize-to-views! self term)))))

;; After each command, every view showing a terminal edits what it should:
;; copy mode's text or line mode's input, or nothing, in case it came
;; back to the buffer, or was restored, after the mode began or ended.
(def (refocus-terminal-views! (self : terminals-state)) => :void
  (when (service-there? layout-service)
    (for-each (lambda ((v : view))
                (let* ((term (hash-get self.by-buffer (view-showing v)))
                       (n (and term (view-node v))))
                  (when term
                    (let (wanted (current-text-node term))
                      (cond
                       ((and n (eq? n wanted)) (void))
                       (wanted (set-view-focus! v wanted (fx1+ (text-size (text-node-content wanted)))))
                       (n (reset-view! v (terminal-buffer term) #f 1 0)
                          (place-at-bottom! term v)))))))
              (view-list))))

;; The text node TERM's views edit now, in copy or line mode, or #f.
(def (current-text-node (term : live-terminal)) => (Maybe node)
  (let ((copy term.copy)
        (line term.line))
    (cond
     (copy (copy-state-text-node copy))
     (line (line-state-text-node line))
     (else #f))))

;; Copy the region of TERM's copy, without the line ends that only wrap
;; and with each line's trailing spaces dropped, onto the kill ring.
(def (copy-region! (term : live-terminal)) => :boolean
  (let (state term.copy)
    (and state (service-there? editing-service) (region-active?)
         (let (text (copy-text-clean (copy-state-copy state) (region-beginning) (region-end)))
           (kill-new text)
           (message (string-append "Copied " (number->string (string-length text)) " characters"))
           #t))))

;;; Line mode

;; Edit a line locally, with ordinary Tuna editing, and send it whole on
;; RET (ghostel-line-mode, eat's line mode): the input is a text shown
;; over the cursor's row from the cursor on. The program sees nothing
;; until RET. On the alternate screen line mode waits, in semi-char mode,
;; until the program leaves it (ghostel's pause), unless the user asked
;; for it there. Typing already at the prompt is not taken into the
;; input: ghostel adopts it from OSC 133 input marks, which come with
;; shell integration (stage 4).
(def (enter-line-mode! (self : terminals-state) (term : live-terminal)) => :void
  (when term.copy (leave-copy-mode! self term))
  (unless term.line
    (let* ((t (new-text ""))
           (n (new-text-node t))
           (wrapper (new-node 'terminal-line-input children: [n] attributes: [(cons 'column 0)])))
      (set-node-keymap! n self.line-map)
      (set! term.line (line-state text-node: n wrapper: wrapper history: term.history index: #f))
      (set! term.line-paused? #f)
      (set! term.input-mode 'line)
      (source-changed! term.status)
      (set-node-keymap! term.root self.line-root-map)
      (refresh-root-attributes! self term)
      (place-line-input! term)
      (for-each (lambda ((v : view)) (set-view-focus! v n 1)) (views-showing term))
      (message "Line mode: RET sends the whole line; C-c C-j to leave"))))

;; Show line mode's input after the cursor's row, from the cursor's
;; column on.
(def (place-line-input! (term : live-terminal)) => :void
  (let (state term.line)
    (when state
      (let* ((row (or term.cursor-row (row-store-last-row term.primary)))
             (cursor (and row (node-attribute row 'cursor)))
             (wrapper (line-state-wrapper state)))
        (set-node-attribute! wrapper 'column (if (vector? cursor) (vector-ref cursor 0) 0))
        (row-store-set-extra! term.primary wrapper (and row (node-attribute row 'number)))))))

;; After a redraw: keep the input at the cursor; on the alternate screen,
;; pause line mode; back on the primary screen, resume it.
(def (follow-line-mode! (self : terminals-state) (term : live-terminal) (screen : :symbol)) => :void
  (cond
   ((and term.line (eq? screen 'alternate))
    (leave-line-mode! self term #f)
    (set! term.input-mode 'semi-char)
    (set-node-keymap! term.root self.semi-char)
    (set! term.line-paused? #t)
    (source-changed! term.status)
    (message "Line mode paused; it comes back when the full-screen program ends"))
   ((and term.line-paused? (eq? screen 'primary) term.cursor-row)
    (enter-line-mode! self term))
   (term.line (place-line-input! term))))

;; End line mode: the input goes to the program as typed, without RET,
;; when HAND-BACK? (ghostel's teardown), or is dropped.
(def (leave-line-mode! (self : terminals-state) (term : live-terminal) (hand-back? : :boolean)) => :void
  (let (state term.line)
    (when state
      (let ((input (text-string (text-node-content (line-state-text-node state)))))
        (set! term.history (line-state-history state))
        (set! term.line #f)
        (row-store-set-extra! term.primary #f #f)
        (for-each (lambda ((v : view)) (reset-view! v (terminal-buffer term) #f 1 0) (place-at-bottom! term v))
                  (views-showing term))
        (when (and hand-back? (not (string-empty? input)))
          (send-input! self term (string->utf8 input)))))))

;; The bytes the key KEY (a libghostty physical key) sends TERM's program.
(def (encoded-key (self : terminals-state) (term : live-terminal) (key : :symbol)) => :u8vector
  (let (mirror term.mirror)
    (if mirror
      (key-encoder-encode self.encoder (ghostty-key-event 'press key) terminal: mirror)
      (u8vector 13))))

;; Send line mode's input and RET, remember it, and start a new line.
(def (line-mode-send! (self : terminals-state) (term : live-terminal)) => :void
  (let (state term.line)
    (when state
      (let* ((t (text-node-content (line-state-text-node state)))
             (input (text-string t))
             (history (line-state-history state)))
        (unless (or (string-empty? input) (and (pair? history) (equal? (car history) input)))
          (set! (line-state-history state)
            (let (kept (cons input history))
              (if (fx> (length kept) (setting-value terminal-line-mode-history-size))
                (take kept (setting-value terminal-line-mode-history-size))
                kept))))
        (set! (line-state-index state) #f)
        (line-mode-replace! state "")
        (text-clear-undo! t)
        (send-input! self term (u8vector-append (string->utf8 input) (encoded-key self term 'enter)))))))

;; Make line mode's input TEXT, point at its end.
(def (line-mode-replace! (state : line-state) (text : :string)) => :void
  (let (t (text-node-content (line-state-text-node state)))
    (text-replace! t 1 (fx1+ (text-size t)) text)
    (when (eq? (view-node (selected-view)) (line-state-text-node state))
      (goto-char (fx1+ (string-length text))))))

;; Show the line sent STEP lines before (1) or after (-1) the one shown.
(def (line-mode-history! (state : line-state) (step : :fixnum)) => :void
  (let* ((history (line-state-history state))
         (index (line-state-index state))
         (next (if index (fx+ index step) (if (fx> step 0) 0 -1))))
    (cond
     ((and (fx>= next 0) (fx< next (length history)))
      (set! (line-state-index state) next)
      (line-mode-replace! state (list-ref history next)))
     ((fx< next 0)
      (set! (line-state-index state) #f)
      (line-mode-replace! state ""))
     (else (void)))))

;;; The mouse

;; What a press over TERM's rows does, for its page script (data-mouse):
;; "program" or "program-motion" (every movement too) while its program
;; takes the mouse in semi-char or char mode; "select" in semi-char mode
;; when terminal-mouse-drag-input-mode enters copy mode; "" otherwise. Copy
;; and line mode keep Tuna's own mouse, as ghostel's do.
(def (mouse-mode (term : live-terminal)) => :string
  (let (mirror term.mirror)
    (cond
     ((and mirror (memq term.input-mode '(semi-char char)) (not (terminal-exit-status term))
           (terminal-mouse-tracking? mirror))
      (if (mode-on? term 'any-mouse) "program-motion" "program"))
     ((and (eq? term.input-mode 'semi-char)
           (buffer-local-value terminal-mouse-drag-input-mode (terminal-buffer term)))
      "select")
     (else ""))))

;; TERM's root's attributes for its page script: its mouse mode, and
;; whether closing a plain browser tab showing it asks first.
(def (refresh-root-attributes! (self : terminals-state) (term : live-terminal)) => :void
  (set-node-attribute! term.root 'mouse (mouse-mode term))
  (set-node-attribute! term.root 'confirm-close
                       (and (not (terminal-exit-status term))
                            (buffer-local-value terminal-confirm-close-tab (terminal-buffer term))
                            #t)))

(def (fact (facts : :t) (key : :string)) => :t
  (and (hash-table? facts) (hash-get facts key)))

(def (view-by-id (id : :t)) => (Maybe view)
  (and (fixnum? id)
       (if (service-there? layout-service)
         (find (lambda ((v : view)) (fx= (view-id v) id)) (view-list))
         (let (v (selected-view)) (and (fx= (view-id v) id) v)))))

;; Select the view a mouse event came from, as a click does.
(def (select-view-of! (v :? view)) => :void
  (when (and v (not (eq? v (selected-view))) (service-there? layout-service))
    (select-view v)))

;; A page's mouse event over a terminal whose program takes the mouse:
;; FACTS {terminal, view, kind (press, release, motion), button (left,
;; middle, right, four, five or null), count, buttons, row, column, y,
;; alt, ctrl, meta, shift}. Encoded by libghostty's mouse encoder for the
;; modes the program asked for, and sent.
(def (mouse-reported! (self : terminals-state) (c : :t) (facts : :t)) => :void
  (let* ((id (fact facts "terminal"))
         (term (and (string? id) (hash-get self.terms id)))
         (mirror (and term (live-terminal-mirror term))))
    (when (and term mirror (not (live-terminal-copy term)) (not (terminal-exit-status term)))
      (let ((kind (fact facts "kind"))
            (button (fact facts "button"))
            (row (fact facts "row"))
            (column (fact facts "column"))
            (y (fact facts "y"))
            (count (fact facts "count")))
        (when (and (member kind ["press" "release" "motion"]) (integer? row) (real? column) (real? y)
                   (or (not button) (member button ["left" "middle" "right" "four" "five"])))
          (unless (equal? kind "motion") (select-view-of! (view-by-id (fact facts "view"))))
          (when c (set! (live-terminal-last-client term) c))
          (let* ((width (fxmax 1 (live-terminal-cell-width term)))
                 (height (fxmax 1 (live-terminal-cell-height term)))
                 (screen-row (- row (row-numbering-active-row (terminal-row-numbering mirror))))
                 (x (* (min column (+ (live-terminal-columns term) 1)) width))
                 (y (* (+ (max -1 (min screen-row (live-terminal-rows term))) y) height))
                 (modifiers (filter-map (lambda ((pair : :pair)) (and (eq? (fact facts (car pair)) #t) (cdr pair)))
                                        '(("shift" . shift) ("ctrl" . ctrl) ("alt" . alt) ("meta" . super))))
                 (event (with-catch (lambda (e) #f)
                                    (lambda () (mouse-event (string->symbol kind) (and button (string->symbol button))
                                                            x y modifiers: modifiers))))
                 (encoder self.mouse-encoder))
            (when event
              (mouse-encoder-set-size! encoder (mouse-encoder-size (* (live-terminal-columns term) width) (* (live-terminal-rows term) height)
                                                                   width height 0 0 0 0))
              (mouse-encoder-set-any-button-pressed! encoder (and (fixnum? (fact facts "buttons"))
                                                                  (fx> (fact facts "buttons") 0)))
              (let (bytes (with-catch (lambda (e) (u8vector))
                                      (lambda () (mouse-encoder-encode encoder event terminal: mirror))))
                (when (fx> (u8vector-length bytes) 0)
                  (set! (live-terminal-last-input term) (now))
                  (let lp ((n (if (and (fixnum? count) (fx< 0 count 100)) count 1)))
                    (when (fx> n 0)
                      (send! term 'input bytes)
                      (lp (fx1- n)))))))))))))

;; What a page selected over a terminal's rows in select mode, or where
;; it was clicked: FACTS {terminal, view, start: {row, index}, end, clicks,
;; wasSelected}. The view is selected; then, as ghostel does
;; (ghostel-mouse-drag-input-mode), a drag, a double or triple click, or a
;; click in a view that was already selected enters copy mode with point
;; at the end and the region from the start.
(def (selection-reported! (self : terminals-state) (c : :t) (facts : :t)) => :void
  (let* ((id (fact facts "terminal"))
         (term (and (string? id) (hash-get self.terms id)))
         (v (view-by-id (fact facts "view")))
         (start (fact facts "start"))
         (end (fact facts "end"))
         (place (lambda (p) (and (hash-table? p) (integer? (hash-get p "row")) (fixnum? (hash-get p "index"))
                                 (cons (hash-get p "row") (hash-get p "index")))))
         (from (place start))
         (to (place end))
         (clicks (fact facts "clicks")))
    (when (and term v from to (not (live-terminal-copy term)) (eq? (view-showing v) (terminal-buffer term)))
      (select-view-of! v)
      (when (and (buffer-local-value terminal-mouse-drag-input-mode (terminal-buffer term))
                 (eq? (live-terminal-input-mode term) 'semi-char)
                 (or (eq? (fact facts "wasSelected") #t) (and (fixnum? clicks) (fx> clicks 1))
                     (not (equal? from to))))
        (parameterize ((current-client c))
          (enter-copy-mode! self term)
          (let ((mark (copy-row-position term (car from) (cdr from)))
                (point (copy-row-position term (car to) (cdr to))))
            (when point
              (goto-char point)
              (when (and mark (not (fx= mark point)) (service-there? editing-service))
                (set-temporary-region! mark)))))))))

;; Enter copy mode and move point to the next or previous link
;; (ghostel-next-hyperlink), wrapping around.
(def (goto-hyperlink! (self : terminals-state) (term : live-terminal) (direction : :symbol)) => :void
  (let* ((state (enter-copy-mode! self term))
         (starts (map copy-link-start (copy-text-links (copy-state-copy state))))
         (here (point))
         (target (if (eq? direction 'next)
                   (or (find (cut fx> <> here) starts) (and (pair? starts) (car starts)))
                   (or (find (cut fx< <> here) (reverse starts)) (and (pair? starts) (last starts))))))
    (if target
      (goto-char target)
      (message "No links in this terminal"))))

;;; Prompt navigation

;; Move to the next or previous prompt (ghostel-next-prompt,
;; ghostel-previous-prompt), from the marks a shell's integration leaves
;; (OSC 133): in copy mode, point goes to where the prompt's input starts;
;; otherwise terminal-prompt-navigation-input-mode enters copy mode first,
;; or, when #f, scrolls TERM's views to the prompt's row.
(def (goto-prompt! (self : terminals-state) (term : live-terminal) (direction : :symbol)) => :void
  (if (or term.copy (buffer-local-value terminal-prompt-navigation-input-mode (terminal-buffer term)))
    (let* ((state (enter-copy-mode! self term))
           (target (copy-text-prompt-target (copy-state-copy state) (copy-state-prompts state) (point) direction)))
      (if target
        (goto-char target)
        (message (if (eq? direction 'next) "No next prompt" "No previous prompt"))))
    (let* ((v (selected-view))
           (store (if (eq? term.screen 'alternate) term.alternate term.primary))
           (top (let (target (placement-target (view-placement v)))
                  (and target (node-attribute (item-node target) 'number))))
           (numbers (map (lambda ((p : :pair)) (+ (row-store-base store) (car p))) (screen-prompts term)))
           (here (if (integer? top) top (row-store-end store)))
           (number (if (eq? direction 'next)
                     (find (cut > <> here) numbers)
                     (find (cut < <> here) (reverse numbers))))
           (row (and number (row-store-row store number))))
      (if row
        (for-each (lambda ((v : view)) (place-view! v (node-item row) 'top)) (views-showing term))
        (message (if (eq? direction 'next) "No next prompt" "No previous prompt"))))))

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
  (set! self.owed (remq term self.owed))
  (when (eq? self.focused term) (set! self.focused #f))
  (let (c term.link)
    (when c
      (when (and kill? (not (terminal-exit-status term)))
        (connection-send! c 'kill))
      (close-connection! c)))
  (set! term.link #f)
  (let (j term.reader) (when j (job-cancel! j)))
  (let (t term.timer) (when t (cancel-timer t)))
  (let (t term.link-timer) (when t (cancel-timer t)))
  (let (t term.fill-timer) (when t (cancel-timer t)))
  (let (b term.inbox) (when b (frame-inbox-close! b)))
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
         (initial (setting-value terminal-initial-input-mode))
         (mode (if (eq? initial 'char) 'char 'semi-char))
         (term (new-live-terminal self id socket name mode (car size) (cdr size)))
         (b (terminal-buffer term))
         (environment (terminal-process-environment (setting-value terminal-environment)
                                                    (setting-value terminal-term)
                                                    (:- (plugin-option terminals 'terminfo) :string)
                                                    directory (process-environment)))
         (integrated (if (setting-value terminal-shell-integration)
                       (shell-integration (shell-command)
                                          (:- (plugin-option terminals 'shell-integration-directory) :string)
                                          environment (and (setting-value terminal-shell-integration-title) #t))
                       (cons (shell-command) [])))
         (launch (make-helper-launch (:- (plugin-option terminals 'helper) :string) socket (car size) (cdr size)
                                     (setting-value terminal-max-scrollback)
                                     (if (string-suffix? "/" directory)
                                       (substring directory 0 (fxmax 1 (fx1- (string-length directory))))
                                       directory)
                                     (path-expand (string-append id ".log") (path-directory socket))
                                     (car integrated)
                                     (first-entries (append (cdr integrated) environment))
                                     (and (leave-scope?) (string-append "tuna-terminal-" id)))))
    (set-buffer-setting! b default-directory directory)
    ;; Line mode starts at the first prompt (ghostel).
    (when (eq? initial 'line) (set! (live-terminal-line-paused? term) #t))
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
            (let* ((term (new-live-terminal self id socket (unique-buffer-name name) (if (eq? mode 'char) 'char 'semi-char)
                                            80 24)))
              ;; Copy mode does not outlive Tuna; line mode comes back.
              (when (eq? mode 'line) (set! (live-terminal-line-paused? term) #t))
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

;; A page script's JSON post as hash tables, or #f.
(def (parse-facts (bytes : :u8vector)) => :t
  (with-catch (lambda (e) #f)
              (lambda ()
                (parameterize ((current-json-read-options (JSONReadOptions object-as-hash: #t)))
                  (string->json (utf8->string bytes))))))

;;; Colours

(def (parse-hex-color (text : :t)) => (Maybe :fixnum)
  (and (string? text) (fx= (string-length text) 7) (char=? (string-ref text 0) #\#)
       (string->number (substring text 1 7) 16)))

;; A page's measured colours, as JSON {foreground, background, cursor,
;; palette: [256]}, each "#rrggbb" or null; #f when they are not.
(def (parse-colors-report (bytes : :u8vector)) => (Maybe theme-colors)
  (with-catch
   (lambda (e) #f)
   (lambda ()
     (let (data (parameterize ((current-json-read-options (JSONReadOptions object-as-hash: #t)))
                  (string->json (utf8->string bytes))))
       (and (hash-table? data)
            (let ((palette (hash-get data "palette")))
              (and (list? palette) (fx<= (length palette) 256)
                   (make-theme-colors (parse-hex-color (hash-get data "foreground"))
                                         (parse-hex-color (hash-get data "background"))
                                         (parse-hex-color (hash-get data "cursor"))
                                         ;; An entry the page could not resolve keeps the
                                         ;; palette's default from there on.
                                         (let lp ((palette palette) (out []))
                                           (let (color (and (pair? palette) (parse-hex-color (car palette))))
                                             (if color
                                               (lp (cdr palette) (cons color out))
                                               (list->vector (reverse out)))))))))))))

;; The colours terminals answer with: the terminal-colors setting's
;; entries, then what a browser measured.
(def (effective-colors (self : terminals-state)) => (Maybe theme-colors)
  (let ((measured self.colors)
        (setting (setting-value terminal-colors)))
    (if (not (list? setting))
      measured
      (let ((given (lambda (key)
                     (let (entry (assq key setting)) (and (pair? entry) (parse-hex-color (cdr entry))))))
            (from-page (lambda (get) (and measured (get measured)))))
        (make-theme-colors (or (given 'foreground) (from-page theme-colors-foreground))
                              (or (given 'background) (from-page theme-colors-background))
                              (or (given 'cursor) (from-page theme-colors-cursor))
                              (let (palette (assq 'palette setting))
                                (if (and (pair? palette) (list? (cdr palette)))
                                  (list->vector (filter-map parse-hex-color (cdr palette)))
                                  (or (from-page theme-colors-palette) (vector)))))))))

(def (send-colors! (self : terminals-state) (term : live-terminal)) => :void
  (let (colors (effective-colors self))
    (when colors (send! term 'colors (colors-payload colors)))))

(def (colors-measured! (self : terminals-state) (colors : theme-colors)) => :void
  (unless (equal? colors self.colors)
    (set! self.colors colors)
    (for-each (cut send-colors! self <>) (hash-values self.terms))))

;;; The status line

;; FORMAT (terminal-status-line-format) for a terminal titled TITLE in
;; FOLDER (#f for none), or #f to show nothing.
(def (status-line-format (format :? :string) (title : :string) (folder :? :string)) => (Maybe :string)
  (and format
       (let ((out (open-output-string))
             (size (string-length format))
             (titled? #t))
         (let lp ((i 0))
           (when (fx< i size)
             (let (c (string-ref format i))
               (if (and (char=? c #\%) (fx< (fx1+ i) size))
                 ;; %[.N](t|d|%)
                 (let* ((dot? (char=? (string-ref format (fx1+ i)) #\.))
                        (digits-end (let digits ((j (if dot? (fx+ i 2) (fx1+ i))))
                                      (if (and (fx< j size) (char-numeric? (string-ref format j))) (digits (fx1+ j)) j)))
                        (limit (and dot? (string->number (substring format (fx+ i 2) digits-end))))
                        (spec (and (fx< digits-end size) (string-ref format digits-end)))
                        (cut-to (lambda ((text : :string))
                                  (if (and limit (fx> (string-length text) limit)) (substring text 0 limit) text))))
                   (case spec
                     ((#\t) (when (string-empty? title) (set! titled? #f)) (write-string (cut-to title) out))
                     ((#\d) (write-string (cut-to (if folder (abbreviated folder) "")) out))
                     ((#\%) (write-char #\% out))
                     (else (write-string (substring format i (fxmin size (fx1+ digits-end))) out)))
                   (lp (fxmin size (fx1+ digits-end))))
                 (begin (write-char c out) (lp (fx1+ i)))))))
         (and titled? (let (text (get-output-string out)) (and (not (string-empty? text)) text))))))

;; What TERM's status line shows after the buffer's name: its title, as
;; terminal-status-line-format says, then the input mode unless semi-char
;; (ghostel's mode-line-process).
(def (status-line-part (term : live-terminal)) => (Maybe :string)
  (record-read! term.status)
  (let ((identification (status-line-format (buffer-local-value terminal-status-line-format (terminal-buffer term))
                                            (terminal-title term) (terminal-directory term)))
        (mode (case term.input-mode
                ((char) ":Char") ((copy) ":Copy") ((line) ":Line") (else #f))))
    (cond
     ((and identification mode) (string-append identification " " mode))
     (else (or identification mode)))))

;;; Drawing nodes

(def (render-terminal (self : terminals-state) (n : node) (children : :list)) => :t
  `(div (@ (class ,(if (eq? (node-attribute n 'screen) 'alternate) "terminal terminal-alternate" "terminal"))
           (data-terminal ,(node-attribute n 'id))
           (data-size ,(or (node-attribute n 'size) ""))
           (data-mouse ,(or (node-attribute n 'mouse) ""))
           ,@(if (node-attribute n 'confirm-close) '((data-confirm-close "")) []))
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
  optional: [layout-service minibuffer-service editing-service files-service file-system-service page-service
             renderer-service]
  (add-stylesheet 'tokens "tokens.css")
  (add-stylesheet 'rules "rules.css")
  (using (self (terminals-state ctx: ctx terms: (make-hash-table) by-buffer: (make-hash-table-eq)
                                semi-char: (new-keymap) char-map: (new-keymap) quote-map: (new-keymap)
                                copy-map: (new-keymap) copy-fast-map: (new-keymap)
                                line-map: (new-keymap) line-root-map: (new-keymap)
                                jobs: (new-job-group ctx) encoder: (make-key-encoder)
                                mouse-encoder: (make-mouse-encoder size: (mouse-encoder-size 80 24 1 1 0 0 0 0)) sizes: (make-hash-table-eq)
                                quoting: [] poster: #f focused: #f yank: 0 waiting: [] owed: [] colors: #f stopping?: #f)
               : terminals-state)
    (context-define-node-kind! ctx 'terminal doc: "A terminal: its rows, scrollback then screen." items: 'children)
    (context-define-node-kind! ctx 'terminal-rows doc: "A run of a terminal's rows." items: 'children)
    (context-define-node-kind! ctx 'terminal-line-input doc: "Line mode's input, over the rest of the cursor's row."
                               items: 'children)
    (context-define-node-renderer! ctx 'terminal-line-input
                                   (lambda (n children)
                                     `(div (@ (class "terminal-line-input")
                                              (style ,(string-append "--terminal-line-input-column:"
                                                                     (number->string (node-attribute n 'column)))))
                                           ,@children)))
    (context-define-node-kind! ctx 'terminal-row doc: "One row of a terminal." items: 'whole
                               project: (lambda (n) (apply string-append
                                                           (map (cut vector-ref <> 2)
                                                                (vector->list (node-attribute n 'runs))))))
    (context-define-node-renderer! ctx 'terminal (lambda (n children) (render-terminal self n children)))
    (context-define-node-renderer! ctx 'terminal-rows (lambda (n children) `(div (@ (class "terminal-rows")) ,@children)))
    (context-define-node-renderer! ctx 'terminal-row
                                   (lambda (n children)
                                     `(div (@ (class "terminal-row") (data-row ,(number->string (node-attribute n 'number))))
                                           ,@(row-sxml (node-attribute n 'runs) (node-attribute n 'cursor)))))
    (when (service-there? page-service)
      (add-script ctx "web/terminal.js")
      (context-add-page-address! ctx "size"
                                 (lambda (c bytes)
                                   (let ((measured (parse-measurements bytes))
                                         (post self.poster))
                                     (when (and measured post)
                                       (post 'terminal-size (lambda () (sizes-measured! self c measured))))))))
    (when (service-there? page-service)
      (for-each (lambda ((address : :pair))
                  (context-add-page-address! ctx (car address)
                                             (lambda (c bytes)
                                               (let ((facts (parse-facts bytes))
                                                     (post self.poster))
                                                 (when (and facts post)
                                                   (post 'terminal-mouse (lambda () ((cdr address) c facts))))))))
                [(cons "mouse" (lambda (c facts) (mouse-reported! self c facts)))
                 (cons "select" (lambda (c facts) (selection-reported! self c facts)))
                 (cons "link" (lambda (c facts)
                                (let ((id (fact facts "terminal"))
                                      (uri (fact facts "uri")))
                                  (when (and (string? id) (string? uri)) (link-clicked! self c id uri)))))])
      (context-add-page-address! ctx "colors"
                                 (lambda (c bytes)
                                   (let ((colors (parse-colors-report bytes))
                                         (post self.poster))
                                     (when (and colors post)
                                       (post 'terminal-colors (lambda () (colors-measured! self colors))))))))
    (context-add-status-line-part! ctx 'terminal
                                   (lambda ((b : buffer))
                                     (let (term (hash-get self.by-buffer b))
                                       (and term (status-line-part term)))))
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
    (context-add-hook! ctx post-command-hook 'terminal-focus
                       (lambda ()
                         (refocus-terminal-views! self)
                         (track-focus! self)))
    (context-add-hook! ctx task-finished-hook 'terminal (lambda (id name how) (draw-owed! self)))
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
    (define-command ctx (terminal-copy-mode) "Freeze the terminal's screen to move over it, select and copy; again, go back."
      (let (term (this-terminal self))
        (if (live-terminal-copy term) (leave-copy-mode! self term) (enter-copy-mode! self term))))
    (define-command ctx (terminal-copy-mode-exit) "Leave copy mode, back to the input mode before it."
      (leave-copy-mode! self (this-terminal self)))
    (define-command ctx (terminal-copy-mode-exit-and-send) "Leave copy mode and send the key typed to the program."
      (let (term (this-terminal self))
        (leave-copy-mode! self term)
        (send-key! self (last-command-event))))
    (define-command ctx (terminal-copy-mode-copy) "Copy the region, as the program wrote it, onto the kill ring; with fast exit, leave copy mode."
      (let (term (this-terminal self))
        (copy-region! term)
        (when (buffer-local-value terminal-readonly-fast-exit (terminal-buffer term))
          (leave-copy-mode! self term))))
    (define-command ctx (terminal-copy-mode-done) "Open the link at point, or copy the region onto the kill ring; leave copy mode."
      (let* ((term (this-terminal self))
             (state (live-terminal-copy term))
             (link (and state (copy-text-link-at (copy-state-copy state) (point)))))
        (unless link (copy-region! term))
        (leave-copy-mode! self term)
        (when link (open-link! self term link))))
    (define-command ctx (terminal-copy-mode-yank) "Leave copy mode and send the newest killed text to the program, as a paste."
      (let (term (this-terminal self))
        (leave-copy-mode! self term)
        (when (service-there? editing-service) (paste! self term (current-kill 0)))))
    (define-command ctx (terminal-copy-mode-paste) "Leave copy mode and send the text the browser pasted to the program."
      (let ((term (this-terminal self))
            (event (last-command-event)))
        (leave-copy-mode! self term)
        (when (paste-event? event) (paste! self term (paste-event-text event)))))
    (define-command ctx (terminal-copy-mode-end) "Move point to the terminal's cursor."
      (let* ((term (this-terminal self))
             (state (live-terminal-copy term)))
        (when state (goto-char (cursor-copy-position term (copy-state-copy state) (copy-state-first state))))))
    (define-command ctx (terminal-next-hyperlink) "Enter copy mode and move to the next link, from the start after the last."
      (goto-hyperlink! self (this-terminal self) 'next))
    (define-command ctx (terminal-previous-hyperlink) "Enter copy mode and move to the link before point, from the end after the first."
      (goto-hyperlink! self (this-terminal self) 'previous))
    (define-command ctx (terminal-next-prompt) "Move to the next prompt a shell's integration marked; outside copy mode, as terminal-prompt-navigation-input-mode says."
      (goto-prompt! self (this-terminal self) 'next))
    (define-command ctx (terminal-previous-prompt) "Move to the previous prompt a shell's integration marked; outside copy mode, as terminal-prompt-navigation-input-mode says."
      (goto-prompt! self (this-terminal self) 'previous))
    (define-command ctx (terminal-set-mark) "Enter copy mode, as terminal-mark-activation-input-mode says, and set the mark at the cursor."
      (let (term (this-terminal self))
        (when (and (buffer-local-value terminal-mark-activation-input-mode (terminal-buffer term))
                   (service-there? editing-service))
          (enter-copy-mode! self term)
          (call-command 'set-mark-command))))
    (define-command ctx (terminal-line-mode) "Edit a line locally and send it whole on RET; on the alternate screen, once the program leaves it."
      (let (term (this-terminal self))
        (if (and (eq? (live-terminal-screen term) 'alternate) (not (live-terminal-line term)))
          (begin (set! (live-terminal-line-paused? term) #t)
                 (message "Line mode waits for the full-screen program to end"))
          (enter-line-mode! self term))))
    (define-command ctx (terminal-line-mode-send) "Send the line to the program, with RET."
      (line-mode-send! self (this-terminal self)))
    (define-command ctx (terminal-line-mode-newline) "Put a line break in the line, sent with it."
      (insert "\n"))
    (define-command ctx (terminal-line-mode-interrupt) "Drop the line and send C-c, an interrupt, to the program."
      (let* ((term (this-terminal self))
             (state (live-terminal-line term)))
        (when state (line-mode-replace! state ""))
        (send-input! self term (u8vector 3))))
    (define-command ctx (terminal-line-mode-delete-char-or-eof) "Delete the next character, or send C-d, an end of input, when the line is empty."
      (let* ((term (this-terminal self))
             (state (live-terminal-line term)))
        (if (and state (fx= 0 (text-size (text-node-content (line-state-text-node state)))))
          (send-input! self term (u8vector 4))
          (call-command 'delete-char))))
    (define-command ctx (terminal-line-mode-history-previous) "Show the line sent before the one shown."
      (let (state (live-terminal-line (this-terminal self)))
        (when state (line-mode-history! state 1))))
    (define-command ctx (terminal-line-mode-history-next) "Show the line sent after the one shown."
      (let (state (live-terminal-line (this-terminal self)))
        (when state (line-mode-history! state -1))))
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
                  ("<paste>" . terminal-paste) ("C-c C-t" . terminal-copy-mode)
                  ("C-c C-n" . terminal-next-hyperlink) ("C-c C-p" . terminal-previous-hyperlink)
                  ("C-c M-n" . terminal-next-prompt) ("C-c M-p" . terminal-previous-prompt)))
      (unless (member "C-SPC" exceptions) (bind self.semi-char "C-SPC" 'terminal-set-mark))
      ;; Copy and line mode: the C-c commands (ghostel-mode-map's), then
      ;; copy mode's own keys.
      (for-each (lambda ((keymap : entry-table))
                  (for-each (lambda ((binding : :pair)) (bind keymap (car binding) (cdr binding)))
                            '(("C-c C-c" . terminal-send-C-c) ("C-c C-z" . terminal-send-C-z)
                              ("C-c C-\\" . terminal-send-C-backslash) ("C-c C-d" . terminal-send-C-d)
                              ("C-c C-t" . terminal-copy-mode) ("C-c C-j" . terminal-semi-char-mode)
                              ("C-c M-d" . terminal-char-mode) ("C-c C-l" . terminal-line-mode)
                              ("C-c C-n" . terminal-next-hyperlink) ("C-c C-p" . terminal-previous-hyperlink)
                              ("C-c M-n" . terminal-next-prompt) ("C-c M-p" . terminal-previous-prompt))))
                ;; The input's own map too: its C-c C-c would hide the
                ;; root's other C-c keys.
                [self.copy-map self.copy-fast-map self.line-root-map self.line-map])
      (for-each (lambda ((keymap : entry-table))
                  (for-each (lambda ((binding : :pair)) (bind keymap (car binding) (cdr binding)))
                            '(("M-w" . terminal-copy-mode-copy) ("C-w" . terminal-copy-mode-copy)
                              ("RET" . terminal-copy-mode-done) ("M->" . terminal-copy-mode-end)
                              ("C-y" . terminal-copy-mode-yank) ("<paste>" . terminal-copy-mode-paste))))
                [self.copy-map self.copy-fast-map])
      (for-each (lambda ((binding : :pair)) (bind self.line-map (car binding) (cdr binding)))
                '(("RET" . terminal-line-mode-send) ("S-RET" . terminal-line-mode-newline)
                  ("C-c C-c" . terminal-line-mode-interrupt) ("C-d" . terminal-line-mode-delete-char-or-eof)
                  ("M-p" . terminal-line-mode-history-previous) ("M-n" . terminal-line-mode-history-next)))
      (bind self.semi-char "C-c C-l" 'terminal-line-mode)
      (for-each (lambda ((binding : :pair)) (bind self.copy-fast-map (car binding) (cdr binding)))
                [(cons printing-char-key 'terminal-copy-mode-exit-and-send)
                 '("q" . terminal-copy-mode-exit) '("C-g" . terminal-copy-mode-exit)])
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
  (shell-integration-directory default-shell-integration-directory
                               "The folder of the shell integration scripts (terminal-shell-integration): tuna.bash, tuna.zsh, tuna.fish and their bootstrap folder."
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
