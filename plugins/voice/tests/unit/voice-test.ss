;;; The voice plugin through the real editor loop, with a stand-in
;;; microphone and a stand-in speech worker (../support/fake-worker.sh),
;;; so no model is needed: C-c v (voice-dictate) starts listening on the
;;; client that pressed it; what the worker recognizes goes in at the
;;; marker, which moves with edits above it; C-c v again stops the
;;; microphone, and the worker's last words still arrive; C-g stops too;
;;; a worker that fails, a microphone that fails, or a missing worker
;;; says why in the echo area; turning the plugin off kills the worker.
(import :std/source
        :std/test
        (only-in :std/os/pid getpid)
        :tuna/kernel
        :tuna/lib/plugin-options
        :tuna/plugins/clients/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/microphone/contract
        :tuna/plugins/voice/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/voice/plugin
        "../../../../tuna/tests/support/kernel"
        "../../../keys/tests/support/keys"
        (only-in "../../../../tuna/tests/support/string-input" test-messages current-message))
(export voice-test)

(def fake-worker (path-expand "../support/fake-worker.sh" (path-expand (this-source-directory))))

;; The model the stand-in worker is given: any file; it writes its
;; process id beside it.
(def model (string-append "/tmp/tuna-voice-test-" (number->string (getpid)) ".model"))

;; The stand-in microphone's captures: client -> (on-chunk . on-failure).
(def captures (make-hash-table-eq))

(defclass stand-in-microphone () final: #t)
(defmethod {start! stand-in-microphone}
  (lambda (self c on-chunk on-failure) (hash-put! captures c (cons on-chunk on-failure))))
(defmethod {stop! stand-in-microphone}
  (lambda (self c) (hash-remove! captures c)))

(defplugin (fake-microphone ctx)
  "Captures nothing: the test hands its chunks to the capture."
  provides: [microphone-service]
  (context-provide! ctx microphone-service (Microphone (stand-in-microphone))))

(defplugin (voice-keys ctx)
  "C-c v: voice-dictate."
  requires: [input-service]
  (keymap-set ctx "C-c v" 'voice-dictate))

(def voice-plugins
  [commands keys test-messages rope-text-store settings buffers fake-microphone voice voice-keys])

(def tab (make-client "tab"))

;; Press KEYS from TAB.
(def (press-keys . keys)
  (for-each (cut press <> client: tab) keys))

;; Say LINE into TAB's microphone, from this thread, as a request thread
;; hands on a chunk; the stand-in worker recognizes it as " LINE".
(def (say! line)
  ((car (hash-ref captures tab)) (string->utf8 (string-append line "\n"))))

(def (wait-until ready?)
  (let lp ((tries 500))
    (cond ((ready?) #t) ((zero? tries) #f) (else (thread-sleep! 0.01) (lp (- tries 1))))))

(def (buffer-text) (call-on-editor-loop (lambda () (text-string (current-text)))))

(def (text-becomes expected)
  (and (wait-until (lambda () (equal? (buffer-text) expected)))
       (buffer-text)))

(def (worker-pid)
  (and (wait-until (lambda () (file-exists? (string-append model ".pid"))))
       (string->number (call-with-input-file (string-append model ".pid") read-line))))

(def (process-gone? pid)
  (wait-until (lambda () (not (file-exists? (string-append "/proc/" (number->string pid)))))))

(def (with-voice thunk worker: (worker fake-worker))
  (hash-clear! captures)
  (with-output-to-file model (lambda () (display "model")))
  (when (file-exists? (string-append model ".pid")) (delete-file (string-append model ".pid")))
  (set-plugin-options! voice [(cons 'worker worker) (cons 'model model)])
  (unwind-protect
    (call-with-fresh-kernel voice-plugins
      (lambda ()
        (start-editor-loop!)
        (thunk)))
    (set-plugin-options! voice [])
    (delete-file model)
    (when (file-exists? (string-append model ".pid")) (delete-file (string-append model ".pid")))))

(def voice-test
  (test-suite "tuna/plugins/voice"
    (test-case "dictated text goes in at the marker as it is recognized; stopping flushes the last words"
      (with-voice
       (lambda ()
         (call-on-editor-loop (lambda () (insert "Notes: ")))
         (press-keys "C-c" "v")
         (check (wait-until (lambda () (hash-key? captures tab))) => #t)
         (check (call-on-editor-loop current-message) => "Listening… (C-c v to stop)")
         (check (call-on-editor-loop voice-listening?) => #t)
         ;; After a space, the piece's own space is dropped; point follows.
         (say! "hello")
         (check (text-becomes "Notes: hello") => "Notes: hello")
         (say! "world")
         (check (text-becomes "Notes: hello world") => "Notes: hello world")
         (check (call-on-editor-loop point) => 19)
         ;; Typing above the marker moves it; point stays where it is put.
         (call-on-editor-loop (lambda () (goto-char 1) (insert "> ")))
         (say! "again")
         (check (text-becomes "> Notes: hello world again") => "> Notes: hello world again")
         (check (call-on-editor-loop point) => 3)
         ;; C-c v stops the microphone; the worker's last words still come.
         (press-keys "C-c" "v")
         (check (wait-until (lambda () (not (hash-key? captures tab)))) => #t)
         (check (text-becomes "> Notes: hello world again end.") => "> Notes: hello world again end.")
         (check (call-on-editor-loop voice-listening?) => #f)
         (check (process-gone? (worker-pid)) => #t))))

    (test-case "pieces said without a pause are one undo group"
      (with-voice
       (lambda ()
         (press-keys "C-c" "v")
         (check (wait-until (lambda () (hash-key? captures tab))) => #t)
         (say! "one")
         (say! "two")
         (check (text-becomes "one two") => "one two")
         (thread-sleep! 1.2)
         (say! "three")
         (check (text-becomes "one two three") => "one two three")
         (call-on-editor-loop (lambda () (text-undo! (current-text) #f)))
         (check (buffer-text) => "one two")
         (call-on-editor-loop (lambda () (text-undo! (current-text) #t)))
         (check (buffer-text) => ""))))

    (test-case "C-g stops dictating"
      (with-voice
       (lambda ()
         (press-keys "C-c" "v")
         (check (wait-until (lambda () (hash-key? captures tab))) => #t)
         (press-keys "C-g")
         (check (wait-until (lambda () (not (call-on-editor-loop voice-listening?)))) => #t)
         (check (hash-key? captures tab) => #f)
         (check (text-becomes "end.") => "end."))))

    (test-case "turning the plugin off kills the worker"
      (with-voice
       (lambda ()
         (press-keys "C-c" "v")
         (check (wait-until (lambda () (hash-key? captures tab))) => #t)
         (let (pid (worker-pid))
           (check (fixnum? pid) => #t)
           (call-on-editor-loop (lambda () (deactivate-plugin! voice)))
           (check (process-gone? pid) => #t)
           (check (hash-key? captures tab) => #f)))))

    (test-case "a missing worker, a failing worker and a failing microphone say why"
      (with-voice
       (lambda ()
         (press-keys "C-c" "v")
         (check (wait-until (lambda () (string-contains (call-on-editor-loop current-message) "make voice-worker")))
                => #t)
         (check (call-on-editor-loop voice-listening?) => #f))
       worker: "/nonexistent/tuna-voice-worker")
      (with-voice
       (lambda ()
         (press-keys "C-c" "v")
         (check (wait-until (lambda () (hash-key? captures tab))) => #t)
         (say! "fail")
         (check (wait-until (lambda () (equal? (call-on-editor-loop current-message) "Speech worker: the model broke")))
                => #t)
         (check (call-on-editor-loop voice-listening?) => #f)
         (check (hash-key? captures tab) => #f)))
      (with-voice
       (lambda ()
         (press-keys "C-c" "v")
         (check (wait-until (lambda () (hash-key? captures tab))) => #t)
         (let (on-failure (cdr (hash-ref captures tab)))
           (call-on-editor-loop (lambda () (on-failure "The browser was not allowed to use the microphone"))))
         (check (call-on-editor-loop current-message) => "The browser was not allowed to use the microphone")
         (check (call-on-editor-loop voice-listening?) => #f)
         (check (process-gone? (worker-pid)) => #t))))))
