(import (tuna) (test) (test-runner) (options) (buffers) (processes) (terminal) (terminal-test)
        (prefix (terminal screens) screens:))

;; A form names the instances of the modules loaded when it is read, so
;; each reload or unload of terminal ends a test, and the next test uses
;; the new instance.

(define t #f)
(define p #f)
(define before #f)

(test "a reload of terminal keeps the shell running, with its buffer and screen"
  (set! t (terminal-test:shell!))
  (set! p (terminal:process t))
  (terminal:send! t "x=kept; seq 1 30\r")
  (terminal-test:wait-for t "\n30\n$ ")
  (set! before (terminal-test:text t))
  (reload-modules! '((terminal))))

(test "after the reload the terminal goes on from the output it had applied"
  (check-equal? (list #t #t #t before)
                (list (eq? t (buffers:find "*terminal*")) (terminal:terminal? t) (eq? p (terminal:process t)) (terminal-test:text t)))
  (terminal:send! t "echo $x\r")
  (terminal-test:wait-for t "\nkept\n$ ")
  (check-equal? '("30" "$ echo $x" "kept" "$ ") (list-tail (terminal-test:screen-lines t) 20)))

(define end-before #f)

(test "while the plugin is off the program goes on, and what it writes waits in the process's log"
  (unload-owner! (module-owner '(terminal)))
  (set! end-before (processes:output-end p))
  (processes:send! p "echo while-off\r")
  (test-runner:wait-until (lambda () (> (processes:output-end p) end-before)))
  (load-module! '(terminal))
  (load-module! '(terminal-test)))

(test "what the program wrote while the plugin was off reaches the screen when the plugin is back"
  (terminal-test:wait-for t "\nwhile-off\n$ ")
  (check-equal? '("kept" "$ echo while-off" "while-off" "$ ") (list-tail (terminal-test:screen-lines t) 20)))

(test "each snapshot is a file only the user can read, in a folder of the plugin's under Tuna's data folder"
  (let* ([root (terminal-test:home-file ".local/share/tuna/terminal")]
         [folders (directory-list root)])
    (check-equal? 1 (length folders))
    (let* ([folder (string-append root "/" (car folders))] [file (string-append folder "/" (processes:id p) ".screen")])
      (check (file-exists? file))
      (check-equal? '("600" "700") (map (lambda (f) (number->string (bitwise-and (get-mode f) #o777) 8)) (list file folder))))))

(test "a reload of buffers closes every buffer, and the plugin makes the terminal again from its snapshot, scrollback and all"
  (set! before (terminal-test:lines (terminal-test:text t)))
  (reload-modules! '((buffers))))

(define t2 #f)

(test "the terminal made again shows the same lines and follows the same process"
  (set! t2 (buffers:find "*terminal*"))
  (check-equal? (list #f #t #t before)
                (list (eq? t t2) (terminal:terminal? t2) (eq? p (terminal:process t2)) (terminal-test:lines (terminal-test:text t2))))
  (terminal:send! t2 "echo again\r")
  (terminal-test:wait-for t2 "\nagain\n$ "))

(test "when the output since the snapshot is no longer in the log, the emulator is reset, a line says output was lost, and the program redraws"
  (options:set! processes:log-size 100)
  (terminal:send! t2 "seq 1 100\r")
  (terminal-test:wait-for t2 "\n100\n$ ")
  (unload-owner! (module-owner '(terminal)))
  ;; A log of 100 bytes no longer holds the start of the output, from
  ;; which this snapshot says to go on.
  (let ([kept (screens:take-screen (processes:id p))])
    (screens:keep-screen! (processes:id p) (car kept) 0))
  (load-module! '(terminal))
  (load-module! '(terminal-test)))

(define t3 #f)

(test "after output was lost the terminal goes on"
  (set! t3 (buffers:find "*terminal*"))
  (terminal:send! t3 "echo redrawn\r")
  (terminal-test:wait-for t3 "\nredrawn\n$ ")
  (check-equal? '("[Output was lost here.]" "redrawn")
                (filter (lambda (l) (member l '("[Output was lost here.]" "redrawn"))) (terminal-test:lines (terminal-test:text t3))))
  (options:unset! processes:log-size))

(define q #f)

(test "a query the program made while the plugin was off is answered when the plugin is back"
  (set! q (terminal-test:start-for-client
            (list "sh" "-c" "stty raw -echo; echo ready; dd bs=1 count=1 >/dev/null 2>&1; printf '\\033[5n'; dd bs=1 count=4 2>/dev/null | od -An -tx1 | tr -s ' \\n' ' '; echo; echo end; read x")))
  (terminal-test:wait-for q "ready")
  (let ([qp (terminal:process q)])
    (unload-owner! (module-owner '(terminal)))
    (let ([end (processes:output-end qp)])
      (processes:send! qp "x")
      (test-runner:wait-until (lambda () (> (processes:output-end qp) end)))))
  (load-module! '(terminal))
  (load-module! '(terminal-test)))

(test "the query's answer reaches the program"
  (check-equal? "1b 5b 30 6e" (terminal-test:read-by q)))

(define a #f)

(test "a reload while the program shows its alternate screen keeps one copy of the scrollback"
  (set! a (terminal-test:shell!))
  (terminal-test:show! a)
  (terminal:send! a "seq 1 40; printf '\\e[?1049h\\e[HALT%sSCREEN' ''; read x; printf '\\e[?1049l'\r")
  (terminal-test:wait-for a "ALTSCREEN")
  (reload-modules! '((terminal))))

(test "the scrollback is copied again whole when the program leaves that screen"
  (terminal:send! a "\r")
  (test-runner:wait-until (lambda () (not (terminal-test:screen-has? a "ALTSCREEN"))))
  (test-runner:wait-until (lambda () (= 42 (length (terminal-test:lines (terminal-test:text a))))))
  (let ([ls (terminal-test:lines (terminal-test:text a))])
    (check-equal? (list 42 1 "$ seq 1 40; printf '\\e[?1049h\\e[HALT%sSCREEN' ''; read x; printf '\\e[?1049l'")
                  (list (length ls) (length (filter (lambda (l) (string=? l "40")) ls)) (car ls)))))
