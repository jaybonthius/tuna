#lang :tuna/prelude
;;; Voice dictation: the voice service, and `voice-dictate`, which inserts
;;; what you say at point, as you say it.
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
        (only-in :std/encoding/json string->json current-json-read-options JSONReadOptions)
        (only-in :std/os/signal kill SIGTERM)
        :std/source
        :std/interface
        :tuna/kernel
        :tuna/lib/plugin-options
        :tuna/plugins/clients/contract
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/microphone/contract
        :tuna/plugins/voice/contract)
(export voice)

;; Seconds a worker may take to end after its input closed.
(def worker-finish-seconds 15)

;; The longest gap between two dictated pieces in one undo group.
(def undo-pause-seconds 1.0)

;;; Listening

;; One listening, from start until its worker ended. STATE is listening,
;; then stopping (the microphone is off and the worker finishing), then
;; ended. Only the editor loop changes it.
(defclass listening ((from     : client)   ; the client whose microphone it is
                     (on-text  : :procedure)
                     (process  : :t)            ; the worker's process port
                     (writer   :? :thread)      ; runs audio-writing-thread
                     (state    : :symbol)
                     (reported? : :boolean))    ; its worker reported an error
  final: #t)

(defclass voice-state ((current  :? listening)  ; the one listening, not stopping
                       (running  : :list)       ; every listening not ended
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

(def (start-listening! (self : voice-state) (c : client) (on-text : :procedure)) => :void
  (when self.current
    (error "Already listening"))
  (unless (file-exists? self.worker)
    (error (string-append "No speech worker at " self.worker "; build it with `make voice-worker`")))
  (unless (file-exists? self.model)
    (error (string-append "No speech model at " self.model)))
  (let* ((process (open-process [path: self.worker
                                 arguments: [self.model self.language]
                                 environment: (worker-environment)
                                 stdin-redirection: #t
                                 stdout-redirection: #t
                                 stderr-redirection: #f]))
         (l (listening from: c on-text: on-text process: process writer: #f
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
                             (stop-listening! self l)))))))

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

;; L's worker wrote EVENT: text, its end, or an error. Editor loop.
(def (worker-said! (self : voice-state) (l : listening) (event : :t)) => :void
  (unless (eq? l.state 'ended)
    (let ((text (hash-get event "text"))
          (error-text (hash-get event "error")))
      (cond
       ((and (string? text) (not (string-empty? text)))
        ((listening-on-text l) text))
       ((string? error-text)
        (set! l.reported? #t)
        (message (string-append "Speech worker: " error-text))
        (stop-listening! self l))))))

;; L's worker ended: on its own, after its input closed, or killed.
(def (worker-ended! (self : voice-state) (l : listening)) => :void
  (unless (eq? l.state 'ended)
    (let (unexpected? (and (eq? l.state 'listening) (not l.reported?)))
      (forget-listening! self l)
      (when unexpected?
        (message "The speech worker stopped unexpectedly")))))

(implement Voice voice-state
  (start! (lambda (self c on-text) (start-listening! self c on-text)))
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

(defplugin (voice ctx)
  "Voice dictation: voice-dictate inserts what you say at point as you say it; C-g or voice-stop stops."
  provides: [voice-service]
  requires: [microphone-service commands-service input-service buffers-service]
  (using (self (voice-state current: #f running: []
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
    ;; C-g stops dictating too, and goes on to quit as always.
    (advise! ctx (command-target 'keyboard-quit) 'voice before:
             (lambda () (when (voice-listening?) (voice-stop!))))))

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
