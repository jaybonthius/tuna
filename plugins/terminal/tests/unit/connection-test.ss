;;; The frame inbox between a terminal's reader and the editor: output
;;; frames that follow each other are joined, and the reader waits while
;;; more than the limit waits.
(import :std/test
        :tuna/plugins/terminal/protocol
        :tuna/plugins/terminal/connection)
(export connection-test)

(def (output (text : :string)) => frame
  (make-frame 'output (string->utf8 text)))

(def connection-test
  (test-suite "tuna/plugins/terminal: the frame inbox"
    (test-case "the editor takes every frame in order, output frames that follow each other joined"
      (let (b (new-frame-inbox 1000))
        (check (frame-inbox-put! b [(output "a") (output "b")]) => #t)
        (check (frame-inbox-put! b [(make-frame 'exit (u8vector 0 3)) (output "c")]) => #f)
        (check (frame-inbox-put! b [(output "d")]) => #f)
        (check (map (lambda (f) (cons (frame-type f) (frame-payload f))) (frame-inbox-take! b))
               => [(cons 'output (string->utf8 "ab")) (cons 'exit (u8vector 0 3)) (cons 'output (string->utf8 "cd"))])
        (check (frame-inbox-take! b) => [])
        ;; Empty again: the next put tells the editor.
        (check (frame-inbox-put! b [(output "e")]) => #t)))

    (test-case "past the limit the reader waits until the editor takes; closing frees it"
      (let* ((b (new-frame-inbox 4))
             (done #f))
        (frame-inbox-put! b [(output "12345")])
        (let (reader (spawn (lambda () (frame-inbox-put! b [(output "6")]) (set! done #t))))
          (thread-sleep! 0.1)
          (check done => #f)
          (check (length (frame-inbox-take! b)) => 1)
          (thread-join! reader 2)
          (check done => #t))
        (frame-inbox-put! b [(output "1234567")])
        (let (reader (spawn (lambda () (frame-inbox-put! b [(output "8")]))))
          (thread-sleep! 0.1)
          (frame-inbox-close! b)
          (check (thread-join! reader 2) => #f)
          (check (frame-inbox-take! b) => []))))))
