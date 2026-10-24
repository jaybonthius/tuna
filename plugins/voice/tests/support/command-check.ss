;;; A manual check of spoken commands against real recordings, run by
;;; `make voice-command-check` (never by `make test`: it needs the speech
;;; worker and a model). It starts Tuna from an init.ss in a fresh kernel,
;;; with its XDG directories in a temporary directory, builds the grammar
;;; voice-command would build there, and runs the speech worker over each
;;; recording twice, after half a second of silence, as voice-command's
;;; listening ends: followed by
;;; enough silence for the model to notice the end of the utterance
;;; ("eou"), and followed by a short pause after which the input closes
;;; and the worker finalizes ("pause"). For each it prints the recognized
;;; text, every candidate with its confidence, and what voice-command
;;; would do with the current settings.
;;;
;;; Usage: gxi command-check.ss WORKER INIT.SS RECORDING.f32 ...
;;; Recordings are raw float32 little-endian mono 16 kHz audio. With
;;; VOICE_COMMAND_GRAMMAR=PATH, the grammar is also written to PATH.
(import :std/misc/ports
        (only-in :std/encoding/json string->json current-json-read-options JSONReadOptions)
        :tuna/kernel
        :tuna/boot
        :tuna/plugins/commands/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/voice/spoken
        :tuna/plugins/voice/plugin
        "../../../../tuna/tests/support/kernel")
(export main)

(def xdg-variables
  '("XDG_CONFIG_HOME" "XDG_STATE_HOME" "XDG_CACHE_HOME" "XDG_DATA_HOME" "XDG_RUNTIME_DIR"))

(def (call-with-isolated-xdg (proc : :procedure)) => :t
  (let (directory (path-expand (string-append "tuna-voice-command-check-"
                                              (number->string (random-integer 1000000000)))
                               (getenv "TMPDIR" "/tmp")))
    (for-each (lambda (name)
                (let (path (path-expand name directory))
                  (create-directory* path)
                  (setenv name path)))
              xdg-variables)
    (try (proc)
         (finally (delete-file-or-directory directory #t)))))

;; Seconds of silence before a recording, as between pressing the key and
;; speaking (the model misses words right at the start of its input); and
;; after it: until the model's end of utterance, and the pause that ends
;; listening.
(def lead-silence 0.5)
(def eou-silence 1.5)
(def pause-silence 0.5)

(def (silence (seconds : :real)) => :u8vector
  (make-u8vector (* 4 (inexact->exact (round (* seconds 16000)))) 0))

;; The worker's documents for AUDIO, then its end of input, as hash tables.
(def (worker-documents (worker : :string) (model : :string) (grammar-path : :string)
                       (audio : :u8vector)) => :list
  (let (process (open-process [path: worker
                               arguments: [model "--grammar" grammar-path "--beam" "8"]
                               stdin-redirection: #t stdout-redirection: #t stderr-redirection: #f]))
    (let (reader (spawn (lambda ()
                          (let lp ((out []))
                            (let (line (read-line process))
                              (if (eof-object? line)
                                (reverse out)
                                (lp (cons (parameterize ((current-json-read-options
                                                          (JSONReadOptions object-as-hash: #t)))
                                            (string->json line))
                                          out))))))))
      ;; 100 ms chunks, as the microphone sends them. A worker that failed
      ;; stops reading; its error is among its documents.
      (with-catch void
        (lambda ()
          (let lp ((offset 0))
            (when (< offset (u8vector-length audio))
              (let (end (min (u8vector-length audio) (+ offset 6400)))
                (write-subu8vector audio offset end process)
                (force-output process)
                (lp end))))
          (close-output-port process)))
      (let (documents (thread-join! reader))
        (process-status process)
        documents))))

(def (confidence-text (c : :real)) => :string
  (let (n (inexact->exact (round (* 100 c))))
    (string-append (number->string (quotient n 100)) "."
                   (let (f (number->string (remainder n 100)))
                     (if (< (string-length f) 2) (string-append "0" f) f)))))

(def (per-frame-text (unit : :t)) => :string
  (let ((frames (hash-ref unit "frames" 0)))
    (if (> frames 0)
      (let (n (inexact->exact (round (* 1000 (/ (- (hash-ref unit "score") (hash-ref unit "free_score")) frames)))))
        (string-append (if (< n 0) "-" "") (number->string (quotient (abs n) 1000)) "."
                       (let (f (number->string (remainder (abs n) 1000)))
                         (string-append (make-string (- 3 (string-length f)) #\0) f))))
      "-")))

(def (decision-text (candidates : :list)) => :string
  (match (command-decision candidates
                           run: (setting-value voice-command-run-confidence)
                           margin: (setting-value voice-command-margin)
                           offer: (setting-value voice-command-offer-confidence)
                           count: (setting-value voice-command-candidates)
                           always-ask: (setting-value voice-command-always-ask))
    (['run command confidence] (string-append "run " (symbol->string command)))
    (['ask offered] (string-append "ask: " (string-join (map (lambda (p) (symbol->string (car p))) offered) ", ")))
    (else "didn't catch a command")))

(def (report (label : :string) (documents : :list) (names : :list)) => :void
  (let (failure (find (lambda (d) (hash-get d "error")) documents))
    (when failure
      (error "The speech worker failed" (hash-get failure "error"))))
  (let* ((units (append-map* (lambda (d) (let (u (hash-get d "units")) (if (list? u) u []))) documents))
         (no-match? (find (lambda (d) (hash-get d "no_match")) documents))
         (partials (filter (lambda (p) (and (string? p) (not (string-empty? p))))
                           (map (lambda (d) (hash-get d "partial")) documents))))
    (if (pair? units)
      (let* ((unit (car units))
             (candidates (unit-candidates unit names)))
        (displayln "  " label ": \"" (hash-ref unit "text") "\" per frame " (per-frame-text unit)
                   " (frames " (hash-ref unit "frames") ", endpoint " (hash-ref unit "endpoint_id") ")")
        (displayln "    candidates: "
                   (string-join (map (lambda (p) (string-append (symbol->string (car p)) " "
                                                                (confidence-text (cdr p))))
                                     candidates)
                                ", "))
        (displayln "    alternatives: "
                   (string-join (map (lambda (a) (string-append "\"" (hash-ref a "text") "\""))
                                     (hash-ref unit "alternatives" []))
                                ", "))
        (displayln "    decision: " (decision-text candidates)))
      (displayln "  " label ": no unit" (if no-match? " (no match)" "")
                 (if (pair? partials) (string-append ", last partial \"" (last partials) "\"") "")
                 "; decision: didn't catch a command"))))

(def (append-map* f xs) (foldr (lambda (x out) (append (f x) out)) [] xs))

(def (main worker init . recordings)
  (call-with-isolated-xdg
   (lambda ()
     (call-with-fresh-kernel []
       (lambda ()
         (let (problem (startup-report-problem (start-from-configuration (make-config-choice init "--config"))))
           (when problem (error "The configuration did not start" problem)))
         (let* ((origin (current-buffer))
                (names (spoken-names (filter (lambda (name)
                                               (let (c (command-ref name))
                                                 (and c ((command-visible? c) c origin))))
                                             (command-names))
                                     (setting-value voice-command-names)))
                (grammar (spoken-names-grammar names))
                (grammar-path (path-expand (string-append "tuna-voice-command-check-"
                                                          (number->string (random-integer 1000000000)) ".txt")
                                           (getenv "TMPDIR" "/tmp")))
                (model (setting-value voice-command-model)))
           (call-with-output-file grammar-path (lambda (port) (write-string grammar port)))
           (when (getenv "VOICE_COMMAND_GRAMMAR" #f)
             (call-with-output-file (getenv "VOICE_COMMAND_GRAMMAR") (lambda (port) (write-string grammar port))))
           (displayln (length names) " spoken names"
                      "; run " (confidence-text (setting-value voice-command-run-confidence))
                      ", margin " (confidence-text (setting-value voice-command-margin))
                      ", offer " (confidence-text (setting-value voice-command-offer-confidence)))
           (try
            (for-each
             (lambda (recording)
               (let (audio (call-with-input-file recording read-all-as-u8vector))
                 (displayln (path-strip-directory recording))
                 (report "eou" (worker-documents worker model grammar-path
                                                 (u8vector-append (silence lead-silence) audio (silence eou-silence)))
                         names)
                 (report "pause" (worker-documents worker model grammar-path
                                                   (u8vector-append (silence lead-silence) audio (silence pause-silence)))
                         names)))
             recordings)
            (finally (delete-file grammar-path)))))))))
