(import (tuna) (test) (test-runner) (timers) (buffers) (document) (processes) (processes-test recorder) (processes-test setting) (processes-test agent-chat) (processes-test searcher)
        (processes-test slow-unloader))

(define (violation thunk)
  (guard (c [(assertion-violation? c) (list (condition-who c) (condition-message c))])
    (thunk)
    'no-violation))

(define (syntax-message form)
  (guard (c [(syntax-violation? c) (condition-message c)])
    (eval form (interaction-environment))
    'no-violation))

(define (start-recorded program arguments . options)
  (let ([r (processes-test/recorder:make)])
    (values (apply processes:start program arguments (processes-test/recorder:on-output r) (processes-test/recorder:on-exit r) options) r)))

(define (seconds-now)
  (let ([t (current-time 'time-monotonic)]) (+ (time-second t) (/ (time-nanosecond t) 1e9))))

(define (write-program! path text)
  (call-with-output-file path (lambda (p) (put-string p text)) 'replace)
  (let-values ([(status out err) (processes:run "chmod" (list "+x" path))])
    (check-equal? 0 status)))

(let ([bin (string-append (getenv "HOME") "/bin")])
  (mkdir bin)
  (write-program! (string-append bin "/pi")
    (string-append
      "#!/bin/sh\n"
      "i=0\n"
      "while :; do i=$((i+1)); echo \"line $i\"; sleep 0.01; done &\n"
      "while read -r request; do echo \"answer $request\"; done\n"
      "kill $!\n"))
  (putenv "PATH" (string-append bin ":" (getenv "PATH"))))

(define (chat-lines)
  (let ([b (buffers:find "*pi*")])
    (let loop ([lines (let split ([text (document:text (buffers:document b))] [start 0] [i 0] [acc '()])
                        (cond
                          [(= i (string-length text)) (reverse acc)]
                          [(char=? (string-ref text i) #\newline)
                           (split text (+ i 1) (+ i 1) (cons (substring text start i) acc))]
                          [else (split text start (+ i 1) acc)]))]
               [numbers '()] [others '()])
      (cond
        [(null? lines) (values (reverse numbers) (reverse others))]
        [(and (> (string-length (car lines)) 5) (string=? (substring (car lines) 0 5) "line "))
         (loop (cdr lines) (cons (string->number (substring (car lines) 5 (string-length (car lines)))) numbers) others)]
        [else (loop (cdr lines) numbers (cons (car lines) others))]))))

(define (line-numbers) (let-values ([(numbers others) (chat-lines)]) numbers))

(define (other-lines) (let-values ([(numbers others) (chat-lines)]) others))

(define (last-line-number) (let ([numbers (line-numbers)]) (if (null? numbers) 0 (car (reverse numbers)))))

(define (wait-for-lines-past n) (test-runner:wait-until (lambda () (> (last-line-number) n))))

(define (consecutive? numbers)
  (let loop ([numbers numbers] [next 1])
    (or (null? numbers) (and (= (car numbers) next) (loop (cdr numbers) (+ next 1))))))

(define (chat-process) (processes:find (car (processes-test/agent-chat:agent))))

(test "a process a module starts for itself stops when the module unloads, its undelivered output dropped and its on-exit skipped"
  (let* ([r (processes-test/recorder:make)] [search (processes-test/searcher:search (processes-test/recorder:on-output r) (processes-test/recorder:on-exit r))])
    (check-equal? (module-owner '(processes-test searcher)) (processes:owner search))
    (test-runner:wait-until (lambda () (pair? (processes-test/recorder:events r))))
    (unload-owner! (module-owner '(processes-test searcher)))
    (test-runner:wait-until (lambda () (processes:status search)))
    (timers:sleep 0.1)
    (check-equal? '((output "first\n" 6)) (processes-test/recorder:events r))
    (check-equal? -1 (processes:status search))
    (check (not (memq search (processes:all))))))

(test "output that arrives while a module that follows the process unloads is not handed to it, and nothing is reported"
  (let ([ticker (processes:start-for-user "sh" '("-c" "while :; do echo tick; sleep 0.01; done"))]
        [r (processes-test/recorder:make)] [reported '()])
    (processes-test/slow-unloader:follow! ticker (processes-test/recorder:on-output r))
    (test-runner:wait-until (lambda () (pair? (processes-test/recorder:events r))))
    (let ([keep (lambda (next c) (set! reported (cons c reported)))])
      (advice-add! report keep)
      (unload-owner! (module-owner '(processes-test slow-unloader)))
      (advice-remove! report keep))
    (let ([handed (processes-test/recorder:events r)])
      (timers:sleep 0.1)
      (check-equal? handed (processes-test/recorder:events r)))
    (check-equal? '() (map condition-message reported))
    (processes:stop! ticker)))

(test "the page's chat with Pi follows its user process again after its own reload, a reload of processes and processes turned off, losing no line"
  (processes-test/agent-chat:chat)
  (wait-for-lines-past 20)
  (let ([agent (chat-process)])
    (check-equal? #f (processes:owner agent))
    (check-equal? (buffers:find "*pi*") (processes:buffer agent))
    (reload-modules! '((processes-test agent-chat)))
    (wait-for-lines-past (+ (last-line-number) 20))
    (check (consecutive? (line-numbers)))
    (reload-modules! '((processes)))
    (check-equal? agent (chat-process))
    (wait-for-lines-past (+ (last-line-number) 20))
    (check (consecutive? (line-numbers)))
    (let ([end (processes:output-end agent)])
      (unload-owner! (module-owner '(processes)))
      (check (not (member '(processes-test agent-chat) (loaded-modules))))
      (load-module! '(processes))
      (test-runner:wait-until (lambda () (> (processes:output-end agent) (+ end 200)))))
    (load-module! '(processes-test agent-chat))
    (wait-for-lines-past (+ (last-line-number) 20))
    (check (consecutive? (line-numbers)))))

(test "when the log no longer holds the offset the chat saved, the chat asks Pi for the messages so far"
  (let ([agent (chat-process)])
    (processes-test/setting:with processes:log-size 50
      (lambda ()
        (unload-owner! (module-owner '(processes-test agent-chat)))
        (let ([end (processes:output-end agent)])
          (test-runner:wait-until (lambda () (> (processes:output-end agent) (+ end 100)))))
        (load-module! '(processes-test agent-chat))
        (test-runner:wait-until (lambda () (member "answer {\"type\":\"get_messages\"}" (other-lines))))
        (check (not (consecutive? (line-numbers))))))))

(test "killing the chat's buffer stops its process, and the chat's on-exit forgets it"
  (let ([agent (chat-process)])
    (check (buffers:kill! (buffers:find "*pi*")))
    (test-runner:wait-until (lambda () (not (processes-test/agent-chat:agent))))
    (check-equal? -1 (processes:status agent))
    (check (not (memq agent (processes:all))))))

(test "processes:stop! hangs up the program's group; on-output is not called again and on-exit runs when it ends; a second stop does nothing"
  (let-values ([(ticker r) (start-recorded "sh" '("-c" "while :; do echo tick; sleep 0.05; done"))])
    (test-runner:wait-until (lambda () (pair? (processes-test/recorder:events r))))
    (processes:stop! ticker)
    (let ([events (reverse (processes-test/recorder:wait-for-exit r))])
      (check-equal? '(exit -1) (car events))
      (check (for-all (lambda (event) (eq? (car event) 'output)) (cdr events))))
    (processes:stop! ticker)))

(test "a program that ignores SIGHUP gets SIGKILL a second later"
  (let-values ([(stubborn r) (start-recorded "sh" '("-c" "trap '' HUP; echo ready; sleep 5"))])
    (test-runner:wait-until (lambda () (pair? (processes-test/recorder:events r))))
    (let ([stopped-at (seconds-now)])
      (processes:stop! stubborn)
      (check-equal? '(exit -9) (car (reverse (processes-test/recorder:wait-for-exit r))))
      (check (>= (- (seconds-now) stopped-at) 1)))))

(test "stopping a process on a terminal closes the terminal, so the kernel hangs up the job in the foreground"
  (let-values ([(job-shell r) (start-recorded "sh" '("-c" "set -m; sleep 30") (processes:options [terminal '(24 . 80)]))])
    (test-runner:wait-until
      (lambda ()
        (let ([group (processes:foreground-group job-shell)])
          (and group (not (= group (processes:pid job-shell)))))))
    (let ([job (processes:foreground-group job-shell)])
      (processes:stop! job-shell)
      (check-equal? '((exit -1)) (processes-test/recorder:wait-for-exit r))
      (test-runner:wait-until (lambda () (not (file-exists? (format "/proc/~a" job))))))))

(test "processes:signal! sends a signal by its name to the program's group, nothing once it has ended, and checks the name"
  (let-values ([(sleeper r) (start-recorded "sleep" '("5"))])
    (processes:signal! sleeper (processes:signal int))
    (check-equal? '((eof 0) (exit -2)) (processes-test/recorder:wait-for-exit r))
    (processes:signal! sleeper (processes:signal term))
    (check-equal? '(processes:signal! "not a processes:signal name") (violation (lambda () (processes:signal! sleeper 'bogus))))
    (check-equal? '(processes:signal! "not a processes:signal name") (violation (lambda () (processes:signal! sleeper "term")))))
  (check-equal? 'hup (processes:signal hup))
  (check-equal? "universe of signal does not include specified symbol" (syntax-message '(processes:signal bogus))))

(test "a process still starting gets a signal once started"
  (let-values ([(p r) (start-recorded "sleep" '("5"))])
    (processes:signal! p (processes:signal term))
    (check-equal? '((eof 0) (exit -15)) (processes-test/recorder:wait-for-exit r))))

(test "killing a process's buffer stops it without asking, and a process whose buffer was unset is not stopped"
  (let ([shell-buffer (buffers:make "*shell*" "")] [linked (processes:start-for-user "sleep" '("5"))] [r (processes-test/recorder:make)])
    (processes:attach! linked 0 (processes-test/recorder:on-output r) (processes-test/recorder:on-exit r))
    (processes:set-buffer! linked shell-buffer)
    (check-equal? shell-buffer (processes:buffer linked))
    (check (buffers:kill! shell-buffer))
    (check-equal? '((exit -1)) (processes-test/recorder:wait-for-exit r))
    (check-equal? #f (processes:buffer linked)))
  (let-values ([(unlinked r) (start-recorded "sleep" '("0.1"))])
    (let ([other-buffer (buffers:make "*other*" "")])
      (processes:set-buffer! unlinked other-buffer)
      (processes:set-buffer! unlinked #f)
      (check (buffers:kill! other-buffer))
      (check-equal? '((eof 0) (exit 0)) (processes-test/recorder:wait-for-exit r))
      (check-equal? '(processes:set-buffer! "not a buffer or #f")
        (violation (lambda () (processes:set-buffer! unlinked "*other*")))))))

(test "while processes is off, killing a process's buffer does not stop it, and once loaded again the process runs on without a live buffer"
  (let ([orphan-buffer (buffers:make "*orphan*" "")] [orphan (processes:start-for-user "sleep" '("30"))])
    (processes:set-buffer! orphan orphan-buffer)
    (unload-owner! (module-owner '(processes)))
    (check (buffers:kill! orphan-buffer))
    (load-module! '(processes))
    (timers:sleep 0.2)
    (check-equal? #f (processes:status orphan))
    (check-equal? #f (processes:buffer orphan))
    (check (memq orphan (processes:all)))
    (processes:stop! orphan)))
