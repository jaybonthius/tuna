;;; The microphone plugin against a stand-in page service: it adds its
;;; page script and its two page addresses; starting a capture sends the
;;; client's page microphoneStart, and the client's chunks reach the
;;; capture's chunk callback, no other client's; a problem the page
;;; reports ends the capture and tells the failure callback why, on the
;;; editor loop; stopping sends microphoneStop and drops later chunks.
(import :std/test
        :tuna/kernel
        :tuna/plugins/clients/contract
        :tuna/plugins/web/contract
        :tuna/plugins/microphone/contract
        :tuna/plugins/microphone/plugin
        "../../../../tuna/tests/support/kernel"
        (only-in "../../../../tuna/tests/support/string-input" test-input))
(export microphone-test)

;; A page service that records what plugins ask of it.
(defclass recording-page (scripts addresses instructions) final: #t)
(defmethod {add-script! recording-page}
  (lambda (self ctx path) (set! (recording-page-scripts self) (cons path (recording-page-scripts self)))))
(defmethod {add-address! recording-page}
  (lambda (self ctx name handler) (hash-put! (recording-page-addresses self) name handler)))
(defmethod {instruct! recording-page}
  (lambda (self c action argument)
    (set! (recording-page-instructions self)
      (cons [(client-id c) action argument] (recording-page-instructions self)))))

(def page (make-recording-page scripts: [] addresses: (make-hash-table) instructions: []))

(defplugin (recording-page-plugin ctx)
  "Records the page scripts, addresses and instructions plugins ask for."
  provides: [page-service]
  (context-provide! ctx page-service (Page page)))

(def microphone-plugins [test-input recording-page-plugin microphone])

;; Post BODY to the microphone's page address NAME from client C, on this
;; thread, as a request thread does.
(def (post! name c body)
  ((hash-ref (recording-page-addresses page) name) c (if (string? body) (string->utf8 body) body)))

(def (wait-until ready?)
  (let lp ((tries 300))
    (cond ((ready?) #t) ((zero? tries) #f) (else (thread-sleep! 0.01) (lp (- tries 1))))))

(def microphone-test
  (test-suite "tuna/plugins/microphone"
    (test-case "the page script and the page addresses are added"
      (set! (recording-page-scripts page) [])
      (call-with-fresh-kernel microphone-plugins
        (lambda ()
          (let (script (car (recording-page-scripts page)))
            (check (string-suffix? "/microphone/web/microphone.js" script) => #t)
            (check (file-exists? script) => #t)
            (check (file-exists? (path-expand "microphone-worklet.js" (path-directory script))) => #t))
          (check (list-sort string<? (hash-keys (recording-page-addresses page))) => ["chunk" "problem"]))))

    (test-case "a capture gets its client's chunks until it stops"
      (set! (recording-page-instructions page) [])
      (call-with-fresh-kernel microphone-plugins
        (lambda ()
          (start-editor-loop!)
          (let ((a (make-client "a"))
                (b (make-client "b"))
                (chunks []))
            (call-on-editor-loop
             (lambda () (microphone-start! a (lambda (bytes) (set! chunks (cons bytes chunks))) void)))
            (let (start (car (recording-page-instructions page)))
              (check (car start) => "a")
              (check (cadr start) => "microphoneStart")
              (check (hash-ref (caddr start) "rate") => 16000)
              (check (hash-ref (caddr start) "chunk") => 1600))
            (post! "chunk" a #u8(1 2 3 4))
            (post! "chunk" b #u8(9 9 9 9))
            (post! "chunk" a #u8(5 6 7 8))
            (check (reverse chunks) => [#u8(1 2 3 4) #u8(5 6 7 8)])
            (call-on-editor-loop (lambda () (microphone-stop! a)))
            (check (car (recording-page-instructions page)) => ["a" "microphoneStop" #t])
            (post! "chunk" a #u8(0 0 0 0))
            (check (length chunks) => 2)))))

    (test-case "a problem the page reports ends the capture and says why on the editor loop"
      (call-with-fresh-kernel microphone-plugins
        (lambda ()
          (start-editor-loop!)
          (let ((a (make-client "a"))
                (failures [])
                (chunks 0))
            (call-on-editor-loop
             (lambda ()
               (microphone-start! a (lambda (bytes) (set! chunks (+ chunks 1)))
                                  (lambda (sentence)
                                    (set! failures (cons [sentence (editor-loop-running?)] failures))))))
            (post! "problem" a "{\"problem\":\"denied\",\"name\":\"NotAllowedError\"}")
            (check (wait-until (lambda () (pair? failures))) => #t)
            (check (caar failures) => "The browser was not allowed to use the microphone")
            (post! "chunk" a #u8(1 2 3 4))
            (check chunks => 0)
            ;; Reported again, or garbled, nothing more is called.
            (post! "problem" a "not json")
            (thread-sleep! 0.1)
            (check (length failures) => 1)))))))
