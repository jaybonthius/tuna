;;; The terminal helper program: a real helper running a real shell, read
;;; through its socket as the terminal plugin reads it. Every helper and
;;; program a test starts is stopped by its exact pid.
(import :std/test
        :tuna/plugins/terminal/protocol
        :tuna/plugins/terminal/connection
        "../support/helpers")
(export helper-test)

;; Run PROC with a helper running sh -c SCRIPT, then make sure the helper
;; and its program are gone.
(def (with-helper (script : :string) (proc : :procedure)) => :t
  (call-with-test-folder
   (lambda (folder)
     (let* ((socket (start-test-helper folder "h" ["/bin/sh" "-c" script]))
            (client (connect-test-client socket)))
       (try
        (check (wait-for (lambda () (test-client-hello client))) => #t)
        (proc folder socket client)
        (finally
         (close-connection! (test-client-connection client))
         (let (hello (test-client-hello client))
           (when hello
             (kill-pid! (helper-hello-child-pid hello))
             (kill-pid! (helper-hello-helper-pid hello))))))))))

(def helper-test
  (test-suite "tuna/plugins/terminal: helper"
    (test-case "it sends its snapshot, then the program's output, then its exit; it ends once that is seen"
      (with-helper "read line; echo \"got $line\"; exit 3"
        (lambda (folder socket client)
          (let (hello (test-client-hello client))
            (check (helper-hello-version hello) => protocol-version)
            (check (pid-alive? (helper-hello-child-pid hello)) => #t)
            (check (wait-for (lambda () (test-client-mirror client))) => #t)
            (connection-send! (test-client-connection client) 'input (string->utf8 "tuna\r"))
            (check (wait-for (lambda () (test-client-status client))) => #t)
            (check (test-client-status client) => 3)
            (check (and (string-contains (test-client-text client) "got tuna") #t) => #t)
            (check (reverse (test-client-frames client)) ? (lambda (types) (equal? (take types 2) '(hello snapshot))))
            (connection-send! (test-client-connection client) 'exit-ack)
            (check (wait-for (lambda () (not (pid-alive? (helper-hello-helper-pid hello))))) => #t)
            (check (file-exists? socket) => #f)))))

    (test-case "it serves one Tuna at a time; the next one gets the screen back"
      (with-helper "echo first; read line; echo \"then $line\"; sleep 30"
        (lambda (folder socket client)
          (check (wait-for (lambda () (string-contains (test-client-text client) "first"))) ? values)
          (let (second (connect-test-client socket))
            (check (wait-for (lambda () (test-client-refused? second))) => #t)
            (close-connection! (test-client-connection second)))
          (close-connection! (test-client-connection client))
          (check (wait-for (lambda () (test-client-ended? client))) => #t)
          (let (again (connect-test-client socket))
            (check (wait-for (lambda () (string-contains (test-client-text again) "first"))) ? values)
            (connection-send! (test-client-connection again) 'input (string->utf8 "more\r"))
            (check (wait-for (lambda () (string-contains (test-client-text again) "then more"))) ? values)
            (close-connection! (test-client-connection again))))))

    (test-case "kill hangs up the program and ends the helper"
      (with-helper "trap '' INT; sleep 60"
        (lambda (folder socket client)
          (let (hello (test-client-hello client))
            (connection-send! (test-client-connection client) 'kill)
            (check (wait-for (lambda () (test-client-status client))) => #t)
            (check (test-client-status client) => (+ 128 1))
            (check (wait-for (lambda () (not (pid-alive? (helper-hello-helper-pid hello))))) => #t)
            (check (pid-alive? (helper-hello-child-pid hello)) => #f)))))))
