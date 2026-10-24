;;; voice-command through the real editor loop, with a stand-in
;;; microphone and a stand-in speech worker in grammar mode
;;; (../support/fake-worker.sh), so no model is needed: what the test
;;; "says" is the grammar stream's documents themselves. C-c c listens on
;;; the client that pressed it with a grammar of the visible commands'
;;; spoken names; a clear unit runs its command; close or unsure
;;; candidates are offered in a completion list, best first and selected,
;;; RET runs it and C-g cancels; a doubtful one says "Didn't catch a
;;; command"; listening ends by itself on a unit, after a pause, once
;;; what was heard can only become one name, or with no speech at all.
(import :std/source
        :std/test
        (only-in :std/os/pid getpid)
        :tuna/kernel
        :tuna/lib/plugin-options
        :tuna/plugins/clients/contract
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/completion/contract
        :tuna/plugins/microphone/contract
        :tuna/plugins/voice/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/layout/plugin
        :tuna/plugins/minibuffer/plugin
        :tuna/plugins/completion/plugin
        :tuna/plugins/voice/plugin
        "../../../../tuna/tests/support/kernel"
        "../../../keys/tests/support/keys"
        "../../../session/tests/support/session"
        "../../../completion/tests/support/toy-completion-ui"
        (only-in "../../../../tuna/tests/support/string-input" test-messages current-message))
(export voice-command-test)

(def fake-worker (path-expand "../support/fake-worker.sh" (path-expand (this-source-directory))))

;; The model the stand-in worker is given: any file; it writes its
;; process id and the grammar it got beside it.
(def model (string-append "/tmp/tuna-voice-command-test-" (number->string (getpid)) ".model"))

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

;; The commands run, most recent first.
(def ran [])

;; Settings for the next start, as (setting . value) pairs; a later pair
;; for the same setting wins.
(def test-settings [])

(defplugin (spoken-commands ctx)
  "C-c c: voice-command; commands to say; the test's settings."
  requires: [input-service commands-service settings-service]
  (keymap-set ctx "C-c c" 'voice-command)
  (for-each (lambda (pair) (context-set-setting! ctx (car pair) (cdr pair))) test-settings)
  (define-command ctx (split-view-right) "Split right." (set! ran (cons 'split-view-right ran)))
  (define-command ctx (split-view-below) "Split below." (set! ran (cons 'split-view-below ran)))
  (define-command ctx (kill-buffer) "Kill a buffer." (set! ran (cons 'kill-buffer ran)))
  (define-command ctx (magit-status) "Show the status." (set! ran (cons 'magit-status ran)))
  (define-command ctx (split-view-2) "Not plain words." (set! ran (cons 'split-view-2 ran)))
  (context-define-command! ctx 'hidden-thing void visible?: (lambda (c origin) #f)))

(def voice-command-plugins
  [commands keys test-messages rope-text-store settings no-session buffers layout minibuffer
   completion toy-completion-ui fake-microphone voice spoken-commands])

(def tab (make-client "tab"))

(def (press-keys . keys)
  (for-each (cut press <> client: tab) keys))

;; Say DOCUMENT, one line the stand-in worker writes back as is.
(def (say! document)
  ((car (hash-ref captures tab)) (string->utf8 (string-append document "\n"))))

(def (wait-until ready?)
  (let lp ((tries 500))
    (cond ((ready?) #t) ((zero? tries) #f) (else (thread-sleep! 0.01) (lp (- tries 1))))))

(def (message-becomes expected)
  (and (wait-until (lambda () (equal? (call-on-editor-loop current-message) expected)))
       expected))

(def (listening?) (hash-key? captures tab))

(def (worker-pid)
  (and (wait-until (lambda () (file-exists? (string-append model ".pid"))))
       (string->number (call-with-input-file (string-append model ".pid") read-line))))

(def (process-gone? pid)
  (wait-until (lambda () (not (file-exists? (string-append "/proc/" (number->string pid)))))))

(def (grammar)
  (and (wait-until (lambda () (file-exists? (string-append model ".grammar"))))
       (call-with-input-file (string-append model ".grammar") read-line)))

;; A grammar stream document with PARTIAL.
(def (partial-document partial)
  (string-append "{\"partial\":\"" partial "\",\"units\":[],\"events\":[]}"))

;; A grammar stream document with one unit: TEXT with SCORE, the free
;; score FREE over FRAMES, and ALTERNATIVES, (text . score) pairs.
(def (unit-document text score free frames (alternatives []))
  (string-append
   "{\"partial\":\"\",\"units\":[{\"text\":\"" text "\",\"endpoint_id\":1024,\"frame\":15,\"t\":1.2,"
   "\"score\":" (number->string score) ",\"free_score\":" (number->string free)
   ",\"frames\":" (number->string frames) ",\"alternatives\":["
   (string-join (map (lambda (a)
                       (string-append "{\"text\":\"" (car a) "\",\"score\":" (number->string (cdr a)) "}"))
                     alternatives)
                ",")
   "]}],\"events\":[]}"))

(def no-match-document "{\"no_match\":true}")

(def (candidate-names)
  (call-on-editor-loop
   (lambda ()
     (let (s (current-completion-session))
       (and s (map candidate-value (CompletionSession-session-candidates s)))))))

(def (selected-name)
  (call-on-editor-loop
   (lambda ()
     (let* ((s (current-completion-session))
            (c (and s (CompletionSession-session-selected s))))
       (and c (candidate-value c))))))

;; Long enough that listening never ends by a timer the test did not ask for.
(def patient-settings
  [(cons voice-command-end-pause 30) (cons voice-command-start-timeout 30)
   (cons voice-command-unique-grace 30)])

(def (with-voice-command thunk settings: (settings []))
  (hash-clear! captures)
  (set! ran [])
  (set! test-settings (append patient-settings settings))
  (with-output-to-file model (lambda () (display "model")))
  (for-each (lambda (suffix)
              (when (file-exists? (string-append model suffix)) (delete-file (string-append model suffix))))
            '(".pid" ".grammar"))
  (set-plugin-options! voice [(cons 'worker fake-worker)])
  (set! test-settings (cons (cons voice-command-model model) test-settings))
  (unwind-protect
    (call-with-fresh-kernel voice-command-plugins
      (lambda ()
        (start-editor-loop!)
        (thunk)))
    (set-plugin-options! voice [])
    (for-each (lambda (suffix)
                (when (file-exists? (string-append model suffix)) (delete-file (string-append model suffix))))
              '("" ".pid" ".grammar"))))

;; Press C-c c and wait until the microphone listens.
(def (start-listening!)
  (press-keys "C-c" "c")
  (check (wait-until listening?) => #t)
  (check (message-becomes "Say a command…") => "Say a command…"))

(def voice-command-test
  (test-suite "tuna/plugins/voice: voice-command"
    (test-case "the grammar has every visible command's spoken name, with overrides and without names that are not plain words"
      (with-voice-command
       (lambda ()
         (start-listening!)
         (let (text (grammar))
           (check (and (string-contains text "\"split view right\"") #t) => #t)
           (check (and (string-contains text "\"voice command\"") #t) => #t)
           (check (and (string-contains text "\"git status\"") #t) => #t)
           (check (string-contains text "magit") => #f)
           (check (string-contains text "split view 2") => #f)
           (check (string-contains text "hidden") => #f)
           (check (string-prefix? "root ::= " text) => #t))
         (press-keys "C-g"))
       settings: [(cons voice-command-names '((magit-status . "Git Status")))]))

    (test-case "a clear command runs, saying which, with the partial shown while it is heard"
      (with-voice-command
       (lambda ()
         (start-listening!)
         (let (pid (worker-pid))
           (say! (partial-document "split view"))
           (check (message-becomes "split view…") => "split view…")
           (say! (unit-document "split view right" -2.5 -2.5 16))
           (check (message-becomes "Ran split-view-right (voice, 1.00)") => "Ran split-view-right (voice, 1.00)")
           (check ran => '(split-view-right))
           (check (listening?) => #f)
           (check (process-gone? pid) => #t)
           (check (call-on-editor-loop voice-listening?) => #f)))))

    (test-case "close candidates are offered best first and selected; RET runs it"
      (with-voice-command
       (lambda ()
         (start-listening!)
         (say! (unit-document "split view right" -2.0 -2.0 20 '(("split view below" . -2.5))))
         (check (wait-until candidate-names) => #t)
         (check (candidate-names) => '(split-view-right split-view-below))
         (check (selected-name) => 'split-view-right)
         (check (listening?) => #f)
         (press-keys "RET")
         (check (wait-until (lambda () (pair? ran))) => #t)
         (check ran => '(split-view-right)))))

    (test-case "a command not confident enough to run is offered alone"
      (with-voice-command
       (lambda ()
         (start-listening!)
         ;; exp(-2/10): 0.82, under the default 0.85.
         (say! (unit-document "kill buffer" -3.0 -1.0 10))
         (check (wait-until candidate-names) => #t)
         (check (candidate-names) => '(kill-buffer))
         (press-keys "RET")
         (check (wait-until (lambda () (pair? ran))) => #t)
         (check ran => '(kill-buffer)))))

    (test-case "nothing confident enough: Didn't catch a command"
      (with-voice-command
       (lambda ()
         (start-listening!)
         (say! (unit-document "kill buffer" -20.0 -1.0 10))
         (check (message-becomes "Didn't catch a command") => "Didn't catch a command")
         (check (candidate-names) => #f)
         (check ran => [])
         (check (listening?) => #f))))

    (test-case "a command in voice-command-always-ask is offered however confident; C-g cancels"
      (with-voice-command
       (lambda ()
         (start-listening!)
         (say! (unit-document "kill buffer" -1.0 -1.0 10))
         (check (wait-until candidate-names) => #t)
         (check (candidate-names) => '(kill-buffer))
         (press-keys "C-g")
         (check (wait-until (lambda () (not (candidate-names)))) => #t)
         (check ran => []))
       settings: [(cons voice-command-always-ask '(kill-buffer))]))

    (test-case "no speech before voice-command-start-timeout: No command heard"
      (with-voice-command
       (lambda ()
         (start-listening!)
         (let (pid (worker-pid))
           (check (message-becomes "No command heard") => "No command heard")
           (check (listening?) => #f)
           (check (process-gone? pid) => #t)
           (check ran => [])))
       settings: [(cons voice-command-start-timeout 0.2)]))

    (test-case "a pause after speech ends listening and decides from the finalized unit"
      (with-voice-command
       (lambda ()
         (start-listening!)
         (say! (string-append "final:" (unit-document "split view below" -1.0 -1.0 12)))
         (say! (partial-document "split view"))
         (check (wait-until (lambda () (pair? ran))) => #t)
         (check ran => '(split-view-below))
         (check (listening?) => #f))
       settings: [(cons voice-command-end-pause 0.2)]))

    (test-case "a partial that is a whole unique name finishes at once"
      (with-voice-command
       (lambda ()
         (start-listening!)
         (say! (string-append "final:" (unit-document "split view right" -1.0 -1.0 12)))
         (say! (partial-document "split view right"))
         (check (wait-until (lambda () (pair? ran))) => #t)
         (check ran => '(split-view-right)))))

    (test-case "a unique beginning finishes after the grace; without a unit then, its command is offered"
      (with-voice-command
       (lambda ()
         (start-listening!)
         (say! (string-append "final:" no-match-document))
         (say! (partial-document "split view r"))
         (check (wait-until (lambda () (not (listening?)))) => #t)
         (check (wait-until candidate-names) => #t)
         (check (candidate-names) => '(split-view-right))
         (press-keys "RET")
         (check (wait-until (lambda () (pair? ran))) => #t)
         (check ran => '(split-view-right)))
       settings: [(cons voice-command-unique-grace 0.2)]))

    (test-case "with voice-command-finish-when-unique off, a unique beginning waits for the pause"
      (with-voice-command
       (lambda ()
         (start-listening!)
         (say! (partial-document "split view right"))
         (thread-sleep! 0.3)
         (check (listening?) => #t)
         (press-keys "C-g"))
       settings: [(cons voice-command-finish-when-unique #f)]))

    (test-case "C-g while listening cancels: the worker stops and nothing runs"
      (with-voice-command
       (lambda ()
         (start-listening!)
         (let (pid (worker-pid))
           (say! (partial-document "split view"))
           (check (message-becomes "split view…") => "split view…")
           (press-keys "C-g")
           (check (wait-until (lambda () (not (listening?)))) => #t)
           (check (process-gone? pid) => #t)
           (check (call-on-editor-loop voice-listening?) => #f)
           (check ran => [])))))))
