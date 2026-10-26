#lang :tuna/prelude
;;; Voice: the voice service; `voice-dictate`, which inserts what you say
;;; at point, as you say it; and `voice-command`, which runs the command
;;; whose name you say.
;;;
;;; Listening starts a speech worker (worker/worker.ss; `make
;;; voice-worker`) for that one listening: the worker ends when its input
;;; does, and starting one takes about 0.4 s, which the microphone's
;;; start-up mostly hides. The microphone's chunks go straight from the
;;; request thread that received them to a thread that writes them to the
;;; worker's input, so audio never waits for the editor; a thread reading
;;; the worker's output posts each line to the editor loop. Stopping
;;; stops the microphone and closes the worker's input; the worker
;;; finalizes what it heard, writes the last pieces and ends. One that
;;; has not ended `worker-finish-seconds` later is stopped. Turning the
;;; plugin off stops the microphone and the worker at once.
;;;
;;; Each dictated piece goes in at point when it arrives, as typing does:
;;; in whatever text the cursor is in, leaving point after it. The model
;;; sends a sentence's punctuation with the next words (". It's"), so a
;;; piece's leading punctuation goes after the previous piece instead,
;;; when that piece is still there and the cursor has moved away. Pieces
;;; arriving less than `undo-pause-seconds` apart, with no other change to
;;; the text between them, are one undo group: undo removes what was said
;;; between pauses (the default model reports no end of an utterance).

(import (only-in :gerbil/runtime/thread spawn-thread)
        (only-in :gerbil/runtime/hash HashTable)
        (only-in :std/encoding/json string->json current-json-read-options JSONReadOptions)
        (only-in :std/os/signal kill SIGTERM)
        (only-in :std/os/pid getpid)
        :std/source
        :std/interface
        :tuna/kernel
        :tuna/lib/plugin-options
        :tuna/plugins/clients/contract
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/completion/contract
        :tuna/plugins/microphone/contract
        :tuna/plugins/voice/contract
        ./spoken)
(export voice
        voice-command-run-confidence
        voice-command-margin
        voice-command-offer-confidence
        voice-command-candidates
        voice-command-always-ask
        voice-command-names
        voice-command-finish-when-unique
        voice-command-unique-grace
        voice-command-end-pause
        voice-command-start-timeout
        voice-command-model)

;; Seconds a worker may take to end after its input closed.
(def worker-finish-seconds 15)

;; The longest gap between two dictated pieces in one undo group.
(def undo-pause-seconds 1.0)

;;; Listening

;; One listening, from start until its worker ended. STATE is listening,
;; then stopping (the microphone is off and the worker finishing), then
;; ended. Only the editor loop changes it. ON-EVENT gets, on the editor
;; loop, each line the worker writes as a hash table, then 'ended when
;; the worker ended, or 'failed when the worker reported an error or the
;; microphone failed (said in the echo area; 'ended follows).
(defclass listening ((from     : client)   ; the client whose microphone it is
                     (on-event : :procedure)
                     (process  : :t)            ; the worker's process port
                     (writer   :? :thread)      ; runs audio-writing-thread
                     (state    : :symbol)
                     (reported? : :boolean))    ; its worker reported an error
  final: #t)

;; One voice-command, from its start until its outcome, which resumes
;; the command waiting in SUSPENSION. STATE is waiting (for speech), then
;; hearing, then finishing (the worker finalizing what it heard), then
;; decided. Only the editor loop touches it.
(defclass command-hearing ((names        : :list)     ; (spoken . commands), from spoken-names
                           (listener     :? listening)
                           (grammar-path : :string)
                           (state        : :symbol)
                           (partial      : :string)   ; what was heard so far
                           (unique       :? :pair)    ; the one name it can still become
                           (unique?      : :boolean)  ; whether to finish once unique
                           (unique-grace : :real)
                           (end-pause    : :real)
                           (post         : :procedure)
                           (start-countdown :? :thread)
                           (pause-countdown :? :thread)
                           (grace-countdown :? :thread)
                           (suspension   : :t)        ; #f until the command waits
                           (outcome      : :t))       ; #f until decided
  final: #t)

(defclass voice-state ((current  :? listening)  ; the one listening, not stopping
                       (running  : :list)       ; every listening not ended
                       (hearing  :? command-hearing) ; the voice-command not decided
                       (worker   : :string)
                       (model    : :string)
                       (language : :string))
  final: #t)

;; Tuna's environment, with OpenMP threads that sleep while they wait;
;; spinning ones keep every core busy (the worker sets this too, by
;; executing itself again, which this saves).
(def (worker-environment) => :list
  (cons "OMP_WAIT_POLICY=PASSIVE"
        (filter-map (lambda ((pair : :pair))
                      (and (not (member (car pair) '("OMP_WAIT_POLICY" "GOMP_SPINCOUNT")))
                           (string-append (car pair) "=" (cdr pair))))
                    (get-environment-variables))))

;; Listen to C's microphone with a worker loading MODEL, given ARGUMENTS
;; after it; ON-EVENT as in listening.
(def (start-listening! (self : voice-state) (c : client) (model : :string) (arguments : :list)
                       (on-event : :procedure)) => listening
  (when self.current
    (error "Already listening"))
  (unless (file-exists? self.worker)
    (error (string-append "No speech worker at " self.worker "; build it with `make voice-worker`")))
  (unless (file-exists? model)
    (error (string-append "No speech model at " model)))
  (let* ((process (open-process [path: self.worker
                                 arguments: (cons model arguments)
                                 environment: (worker-environment)
                                 stdin-redirection: #t
                                 stdout-redirection: #t
                                 stderr-redirection: #f]))
         (l (listening from: c on-event: on-event process: process writer: #f
                       state: 'listening reported?: #f))
         (post (result-poster)))
    (set! (listening-writer l) (spawn-thread (lambda () (audio-writing-thread l)) 'voice-audio))
    (spawn-thread (lambda () (worker-reading-thread self l post)) 'voice-worker)
    (set! self.current l)
    (set! self.running (cons l self.running))
    (let (writer (listening-writer l))
      (microphone-start! c
                         (lambda ((bytes : :u8vector)) (thread-send writer bytes))
                         (lambda ((sentence : :string))
                           (when (eq? (listening-state l) 'listening)
                             (message sentence)
                             (stop-listening! self l)
                             ((listening-on-event l) 'failed)))))
    l))

;; Stop L's microphone and close its worker's input, so that the worker
;; finishes. Editor loop.
(def (stop-listening! (self : voice-state) (l : listening)) => :void
  (when (eq? l.state 'listening)
    (set! l.state 'stopping)
    (when (eq? self.current l)
      (set! self.current #f))
    (microphone-stop! l.from)
    (thread-send (:- l.writer :thread) 'close)))

;; L's worker ended. Editor loop.
(def (forget-listening! (self : voice-state) (l : listening)) => :void
  (when (eq? l.state 'listening)
    ;; The microphone may be off already, when it turned off first.
    (with-catch void (lambda () (microphone-stop! l.from))))
  (set! l.state 'ended)
  (when (eq? self.current l)
    (set! self.current #f))
  (set! self.running (remq l self.running)))

;; Stop L now: its microphone, and its worker with SIGTERM. Editor loop.
(def (kill-listening! (self : voice-state) (l : listening)) => :void
  (unless (eq? l.state 'ended)
    (forget-listening! self l)
    (thread-send (:- l.writer :thread) 'close)
    (with-catch void (lambda () (kill (process-pid l.process) SIGTERM)))))

;; Write each chunk of audio sent to this thread to L's worker, until sent
;; 'close: then close the worker's input, and stop a worker that has not
;; ended worker-finish-seconds later. A worker that went away makes
;; writing fail; its reader reports that.
(def (audio-writing-thread (l : listening)) => :void
  (let ((port l.process))
    (let lp ((broken? #f))
      (let (item (thread-receive))
        (cond
         ((u8vector? item)
          (lp (or broken?
                  (not (with-catch (lambda (e) #f)
                                   (lambda ()
                                     (write-subu8vector item 0 (u8vector-length item) port)
                                     (force-output port)
                                     #t))))))
         ((eq? item 'close)
          (with-catch void (lambda () (close-output-port port)))
          (thread-sleep! worker-finish-seconds)
          (unless (eq? l.state 'ended)
            (with-catch void (lambda () (kill (process-pid port) SIGTERM)))))
         (else (lp broken?)))))))

;; A line the worker wrote, as a hash table, or #f when it is not a JSON
;; object.
(def (parse-worker-line (line : :string)) => :t
  (let (value (with-catch (lambda (e) #f)
                          (lambda ()
                            (parameterize ((current-json-read-options (JSONReadOptions object-as-hash: #t)))
                              (string->json line)))))
    (and (hash-table? value) value)))

;; Post each line L's worker writes to the editor loop with POST, then its
;; end.
(def (worker-reading-thread (self : voice-state) (l : listening) (post : :procedure)) => :void
  (let lp ()
    (let (line (with-catch (lambda (e) (eof-object)) (lambda () (read-line l.process))))
      (if (eof-object? line)
        (begin
          (with-catch void (lambda () (process-status l.process)))
          (post 'voice-worker-ended (lambda () (worker-ended! self l))))
        (let (event (parse-worker-line line))
          (when event
            (post 'voice-worker-line (lambda () (worker-said! self l event))))
          (lp))))))

;; L's worker wrote EVENT: a result, or an error. Editor loop.
(def (worker-said! (self : voice-state) (l : listening) (event : HashTable)) => :void
  (unless (eq? l.state 'ended)
    (let (error-text (hash-get event "error"))
      (if (string? error-text)
        (begin
          (set! l.reported? #t)
          (message (string-append "Speech worker: " error-text))
          (stop-listening! self l)
          (l.on-event 'failed))
        (l.on-event event)))))

;; L's worker ended: on its own, after its input closed, or killed.
(def (worker-ended! (self : voice-state) (l : listening)) => :void
  (unless (eq? l.state 'ended)
    (let (unexpected? (and (eq? l.state 'listening) (not l.reported?)))
      (forget-listening! self l)
      (when unexpected?
        (message "The speech worker stopped unexpectedly")
        (l.on-event 'failed))
      (l.on-event 'ended))))

;; Dictation's worker events: each text goes to ON-TEXT.
(def (dictation-events (on-text : :procedure)) => :procedure
  (lambda (event)
    (when (hash-table? event)
      (let (text (hash-get event "text"))
        (when (and (string? text) (not (string-empty? text)))
          (on-text text))))))

(implement Voice voice-state
  (start! (lambda (self c on-text)
            (start-listening! self c self.model [self.language] (dictation-events on-text))
            (void)))
  (stop! (lambda (self) (let (l self.current) (when l (stop-listening! self l)))))
  (listening? (lambda (self) (and self.current #t))))

;;; Dictation

;; The text the last dictated piece went into, LAST-TEXT; where the piece
;; starts and ends there, LAST-START and LAST-END, valid at LAST-REVISION,
;; the text's character revision after the piece; and when, LAST-TIME.
(defclass dictation ((last-text     :? text)
                     (last-start    : :fixnum)
                     (last-end      : :fixnum)
                     (last-revision : :fixnum)
                     (last-time     : :real))
  final: #t)

;; Punctuation that belongs to the word before it. The streaming model
;; sends a sentence's punctuation with the words after it (". It's"), so
;; a piece's leading run of these goes after the previous piece.
(def attached-punctuation
  '(#\. #\, #\? #\! #\; #\: #\… #\) #\] #\} #\” #\’ #\»))

(def (leading-punctuation-length (piece : :string)) => :fixnum
  (let lp ((i 0))
    (if (and (fx< i (string-length piece))
             (memv (string-ref piece i) attached-punctuation))
      (lp (fx1+ i))
      i)))

(def (now-seconds) => :real
  (time->seconds (current-time)))

(def (whitespace-before? (t : text) (position : :fixnum)) => :boolean
  (or (fx= position 1)
      (char-whitespace? (string-ref (text-substring t (fx1- position) position) 0))))

(def (string-trim-start (s : :string)) => :string
  (let lp ((i 0))
    (if (and (fx< i (string-length s)) (char-whitespace? (string-ref s i)))
      (lp (fx1+ i))
      (substring s i (string-length s)))))

;; Where D's last piece ends now, when punctuation can go there: its
;; text is alive, some of the piece is left, and the character before its
;; end is not whitespace. Otherwise #f.
(def (last-piece-end (d : dictation)) => (Maybe :fixnum)
  (let (t d.last-text)
    (and t
         (text-live? t)
         (let ((start (relocate-position t d.last-start d.last-revision))
               (end (relocate-position t d.last-end d.last-revision)))
           (and (fx< start end)
                (not (whitespace-before? t end))
                end)))))

(def (remember-piece! (d : dictation) (t : text) (start : :fixnum) (end : :fixnum) (now : :real)) => :void
  (set! d.last-text t)
  (set! d.last-start start)
  (set! d.last-end end)
  (set! d.last-revision (text-chars-revision t))
  (set! d.last-time now))

;; Insert PIECE: its leading punctuation after the last piece, when that
;; piece is still there and the cursor is elsewhere, and the rest at
;; point, without its leading space at the start of a line or after
;; whitespace, leaving point after it. With no text at point, say so and
;; drop the rest.
(def (insert-dictated! (d : dictation) (piece : :string)) => :void
  (let* ((now (now-seconds))
         (n (current-text-node))
         (t (and n (text-node-content n)))
         (punctuation-length (leading-punctuation-length piece))
         (end (and (fx> punctuation-length 0) (last-piece-end d)))
         (attach-end (and end (not (and (eq? t d.last-text) (fx= end (point)))) end))
         (rest (if attach-end (substring piece punctuation-length (string-length piece)) piece)))
    (let (last d.last-text)
      (when (and last
                 (or attach-end (eq? t last))
                 (fx= d.last-revision (text-chars-revision last))
                 (< (- now d.last-time) undo-pause-seconds))
        (undo-amalgamate! last 1000000)))
    (when attach-end
      (let* ((last (:- d.last-text text))
             (start (relocate-position last d.last-start d.last-revision)))
        (text-replace! last attach-end attach-end (substring piece 0 punctuation-length)
                       point-before: (and (eq? t last) (point)))
        (remember-piece! d last start (fx+ attach-end punctuation-length) now)))
    (cond
     ((string-empty? rest) (void))
     ((not t) (message "No text here to dictate into"))
     (else
      (let* ((start (point))
             (rest (if (whitespace-before? t start) (string-trim-start rest) rest)))
        (unless (string-empty? rest)
          (insert rest)
          (remember-piece! d t start (point) now)))))))

;; The keys that run COMMAND, for the echo area, or M-x COMMAND.
(def (keys-for (command : :symbol)) => :string
  (let (keys (where-is command))
    (if (pair? keys)
      (:- (car keys) :string)
      (string-append "M-x " (symbol->string command)))))

(def (start-dictation!) => :void
  (let (d (dictation last-text: #f last-start: 1 last-end: 1 last-revision: 0 last-time: 0))
    (voice-start! (lambda ((piece : :string)) (insert-dictated! d piece)))
    (message (string-append "Listening… (" (keys-for 'voice-dictate) " to stop)"))))

;;; Spoken commands
;;;
;;; voice-command listens with a grammar of the visible commands' spoken
;;; names (spoken.ss), written to a file for a grammar worker started for
;;; that one command, and with voice-command-model, which reports the end
;;; of an utterance. The command waits (suspend) while the worker's lines
;;; and the countdowns below arrive on the editor loop; the first of these
;;; decides, and resumes it with the outcome:
;;; - a committed unit;
;;; - no new partial for voice-command-end-pause seconds after speech, or
;;;   a partial that can only become one spoken name (at once when it is
;;;   the whole name, else after voice-command-unique-grace seconds):
;;;   these stop the microphone and close the worker's input, and the
;;;   finalized document decides (without a unit, the unique name is
;;;   offered, else nothing matched);
;;; - the worker saying it can match nothing more;
;;; - no partial within voice-command-start-timeout seconds;
;;; - C-g, a failing microphone or worker: cancelled.
;;; Then, in the command, the confidence rule (spoken.ss) runs the command,
;;; offers the list through completing-read, or says nothing matched.

(defsetting voice-command-run-confidence 0.85
  "Run a spoken command without asking when it is at least this confident (0 to 1; above 1 always asks).")
(defsetting voice-command-margin 0.1
  "...and at least this much more confident than the next best command.")
(defsetting voice-command-offer-confidence 0.4
  "Offer only commands at least this confident; with none, \"Didn't catch a command\".")
(defsetting voice-command-candidates 5 "At most this many commands in the list a spoken command offers.")
(defsetting voice-command-always-ask []
  "Commands a spoken command always asks about, however confident, as a list of names.")
(defsetting voice-command-names []
  "Spoken names for commands, as (command . \"words\") pairs, such as ((magit-status . \"git status\")).")
(defsetting voice-command-finish-when-unique #t
  "Stop listening as soon as what was said can only become one command.")
(defsetting voice-command-unique-grace 0.4
  "Seconds to wait, once what was said can only become one command, for the rest of its name.")
(defsetting voice-command-end-pause 0.5
  "Seconds without anything new heard, after speech, that end listening for a command.")
(defsetting voice-command-start-timeout 5
  "Seconds to wait for speech before giving up on a spoken command.")
(defsetting voice-command-model
  "/home/jay/Code/workbench-gerbil/gerbil-parakeet/.deps/models/realtime_eou_120m-v1-q8_0.gguf"
  "The speech model for spoken commands (a parakeet.cpp GGUF streaming model with grammar support).")

;; The beam the worker searches the grammar with: it reports at most one
;; fewer alternatives.
(def command-beam-size "8")

;; The commands visible from ORIGIN.
(def (visible-commands (origin : buffer)) => :list
  (filter (lambda ((name : :symbol))
            (let (c (command-ref name))
              (and c ((command-visible? c) c origin))))
          (command-names)))

(def grammar-file-count 0)

;; Write GRAMMAR to a new file and return its path.
(def (write-grammar-file! (grammar : :string)) => :string
  (set! grammar-file-count (fx1+ grammar-file-count))
  (let (path (path-expand (string-append "tuna-voice-grammar-" (number->string (getpid)) "-"
                                         (number->string grammar-file-count) ".txt")
                          (or (getenv "TMPDIR" #f) "/tmp")))
    (call-with-output-file [path: path permissions: #o600 truncate: #t]
      (lambda (port) (write-string grammar port)))
    path))

(def (delete-grammar-file! (h : command-hearing)) => :void
  (with-catch void (lambda () (when (file-exists? h.grammar-path) (delete-file h.grammar-path)))))

;; Run THUNK on the editor loop with POST after SECONDS, unless the
;; returned thread is sent a message first.
(def (start-countdown (post : :procedure) (seconds : :real) (thunk : :procedure)) => :thread
  (spawn-thread (lambda ()
                  (unless (thread-receive seconds #f)
                    (post 'voice-command-countdown thunk)))
                'voice-command-countdown))

(def (stop-countdown! (countdown :? :thread)) => :void
  (when countdown
    (thread-send countdown 'stop)))

(def (string-trim-spaces (s : :string)) => :string
  (string-join (filter (lambda ((word : :string)) (not (string-empty? word))) (string-split s #\space))
               " "))

;; H's outcome is OUTCOME: (heard . candidates), (unique . commands),
;; no-match, no-speech or cancelled. Stop listening: gracefully, the
;; worker finishing in the background, unless cancelled or nothing was
;; said; then resume the command. Editor loop.
(def (decide! (self : voice-state) (h : command-hearing) (outcome : :t)) => :void
  (unless (eq? h.state 'decided)
    (set! h.state 'decided)
    (set! h.outcome outcome)
    (when (eq? self.hearing h)
      (set! self.hearing #f))
    (stop-countdown! h.start-countdown)
    (stop-countdown! h.pause-countdown)
    (stop-countdown! h.grace-countdown)
    (let (l h.listener)
      (when l
        (if (memq outcome '(cancelled no-speech))
          (kill-listening! self l)
          (stop-listening! self l))))
    (when h.suspension
      (resume! h.suspension outcome))))

;; Stop listening and let the worker finalize what it heard. Editor loop.
(def (finish-hearing! (self : voice-state) (h : command-hearing)) => :void
  (when (memq h.state '(waiting hearing))
    (set! h.state 'finishing)
    (stop-countdown! h.pause-countdown)
    (stop-countdown! h.grace-countdown)
    (let (l h.listener)
      (when l (stop-listening! self l)))))

;; The outcome when no unit came: the one name what was heard could still
;; become, if finishing early found one, else no match.
(def (unmatched-outcome (h : command-hearing)) => :t
  (let (unique h.unique)
    (if unique
      (cons 'unique (cdr unique))
      'no-match)))

;; What was heard so far is PARTIAL. Editor loop.
(def (heard-partial! (self : voice-state) (h : command-hearing) (partial : :string)) => :void
  (unless (or (equal? partial h.partial) (not (memq h.state '(waiting hearing))))
    (set! h.partial partial)
    (unless (string-empty? partial)
      (when (eq? h.state 'waiting)
        (set! h.state 'hearing)
        (stop-countdown! h.start-countdown))
      (message (string-append partial "…"))
      (stop-countdown! h.pause-countdown)
      (set! h.pause-countdown
        (start-countdown h.post h.end-pause
                         (lambda () (when (eq? h.state 'hearing) (finish-hearing! self h)))))
      (when h.unique?
        (let (matches (spoken-names-starting-with h.names partial))
          (if (and (pair? matches) (null? (cdr matches)))
            (begin
              (set! h.unique (car matches))
              (cond
               ((equal? (caar matches) partial) (finish-hearing! self h))
               ((not h.grace-countdown)
                (set! h.grace-countdown
                  (start-countdown h.post h.unique-grace
                                   (lambda () (when (eq? h.state 'hearing) (finish-hearing! self h))))))))
            (begin
              (set! h.unique #f)
              (stop-countdown! h.grace-countdown)
              (set! h.grace-countdown #f))))))))

;; H's worker wrote EVENT, or ended or failed. Editor loop.
(def (hearing-event! (self : voice-state) (h : command-hearing) (event : :t)) => :void
  (unless (eq? h.state 'decided)
    (cond
     ((eq? event 'failed) (decide! self h 'cancelled))
     ((eq? event 'ended)
      (decide! self h (if (eq? h.state 'finishing) (unmatched-outcome h) 'cancelled)))
     ((hash-get event "ready") (delete-grammar-file! h))
     ((hash-get event "no_match") (decide! self h (unmatched-outcome h)))
     (else
      (let ((units (hash-get event "units"))
            (partial (hash-get event "partial")))
        (cond
         ((and (pair? units) (hash-table? (car units)))
          (decide! self h (cons 'heard (unit-candidates (car units) h.names))))
         ((string? partial)
          (heard-partial! self h (string-trim-spaces partial)))))))))

;; CONFIDENCE as a number with two decimals.
(def (confidence-text (confidence : :real)) => :string
  (let* ((hundredths (inexact->exact (round (* 100 confidence))))
         (fraction (number->string (remainder hundredths 100))))
    (string-append (number->string (quotient hundredths 100)) "."
                   (if (fx< (string-length fraction) 2) (string-append "0" fraction) fraction))))

;; Ask which of CANDIDATES, (command . confidence) pairs, to run, the
;; first selected, and return it.
(def (choose-command (candidates : :list)) => :symbol
  (completing-read "Voice command: "
                   [(make-completion-table
                     category: 'command
                     items: (map (lambda ((pair : :pair))
                                   (let (name (car pair))
                                     (make-candidate text: (symbol->string name) value: name key: name)))
                                 candidates)
                     ;; Keep the order: most confident first.
                     sort: (lambda (rows) rows))]))

;; Act on what the command heard, OUTCOME.
(def (act-on-hearing! (outcome : :t)) => :void
  (match outcome
    (['heard . candidates]
     (match (command-decision candidates
                              run: (setting-value voice-command-run-confidence)
                              margin: (setting-value voice-command-margin)
                              offer: (setting-value voice-command-offer-confidence)
                              count: (setting-value voice-command-candidates)
                              always-ask: (setting-value voice-command-always-ask))
       (['run command confidence]
        (message (string-append "Ran " (symbol->string command)
                                " (voice, " (confidence-text confidence) ")"))
        (call-command command))
       (['ask offered] (call-command (choose-command offered)))
       (else (message "Didn't catch a command"))))
    (['unique . commands]
     (call-command (choose-command (map (lambda (command) (cons command 0)) commands))))
    ('no-match (message "Didn't catch a command"))
    ('no-speech (message "No command heard"))
    (else (void))))

;; Listen for a command's spoken name, then run it, offer a list, or say
;; nothing matched. Call from the command's task.
(def (hear-command! (self : voice-state)) => :void
  (let ((c (current-client))
        (names (spoken-names (visible-commands (current-buffer)) (setting-value voice-command-names))))
    (using (h (command-hearing names: names listener: #f
                               grammar-path: (write-grammar-file! (spoken-names-grammar names))
                               state: 'waiting partial: "" unique: #f
                               unique?: (setting-value voice-command-finish-when-unique)
                               unique-grace: (setting-value voice-command-unique-grace)
                               end-pause: (setting-value voice-command-end-pause)
                               post: (result-poster)
                               start-countdown: #f pause-countdown: #f grace-countdown: #f
                               suspension: #f outcome: #f)
              : command-hearing)
      (unwind-protect
        (begin
          (unless c
            (error "Listening needs a browser tab"))
          (set! h.listener
            (start-listening! self c (setting-value voice-command-model)
                              ["--grammar" h.grammar-path "--beam" command-beam-size]
                              (lambda (event) (hearing-event! self h event))))
          (set! self.hearing h)
          (set! h.start-countdown
            (start-countdown h.post (setting-value voice-command-start-timeout)
                             (lambda () (when (eq? h.state 'waiting) (decide! self h 'no-speech)))))
          (message "Say a command…")
          (act-on-hearing! (or h.outcome (suspend (lambda (s) (set! h.suspension s))))))
        ;; Quit or an error before the outcome.
        (decide! self h 'cancelled)
        (delete-grammar-file! h)))))

(defplugin (voice ctx)
  "Voice: voice-dictate inserts what you say at point as you say it; voice-command runs the command whose name you say; C-g stops either."
  provides: [voice-service]
  requires: [microphone-service commands-service input-service buffers-service settings-service]
  optional: [completion-service completion-ui-service]
  (using (self (voice-state current: #f running: [] hearing: #f
                            worker: (plugin-option voice 'worker)
                            model: (plugin-option voice 'model)
                            language: (plugin-option voice 'language))
               : voice-state)
    (context-provide! ctx voice-service (Voice self))
    (context-defer! ctx (lambda () (for-each (cut kill-listening! self <>) self.running)))
    (defcommand (voice-dictate)
      "Start dictating: insert what you say at point, as you say it; run it again to stop."
      (if (voice-listening?)
        (begin (voice-stop!) (message "Stopped dictating"))
        (start-dictation!)))
    (defcommand (voice-stop) "Stop dictating."
      (if (voice-listening?)
        (begin (voice-stop!) (message "Stopped dictating"))
        (message "Not dictating")))
    (defcommand (voice-command)
      "Say a command's name to run it: listening ends by itself; an unclear name offers a list."
      (hear-command! self))
    ;; C-g cancels a spoken command or stops dictating, and goes on to
    ;; quit as always.
    (advise! ctx (command-target 'keyboard-quit) 'voice before:
             (lambda ()
               (let (h self.hearing)
                 (cond
                  (h (decide! self h 'cancelled))
                  ((voice-listening?) (voice-stop!))))))))

;; This checkout's build of the speech worker: beside this source, two
;; directories up, in .gerbil/bin.
(def default-worker-path
  (let (root (path-expand "../.." (path-expand (this-source-directory))))
    (path-expand ".gerbil/bin/tuna-voice-worker"
                 (with-catch (lambda (e) root) (lambda () (path-normalize root))))))

(defplugin-options voice
  (worker default-worker-path
          "The speech worker program; `make voice-worker` builds it into .gerbil/bin."
          string-type)
  (model "/home/jay/Code/workbench-gerbil/gerbil-parakeet/.deps/models/nemotron-3.5-asr-streaming-0.6b-q8_0.gguf"
         "The speech model file the worker loads (a parakeet.cpp GGUF streaming model)."
         string-type)
  (language "" "The language the model listens for, such as \"en\"; \"\" leaves it to the model."
            string-type))
