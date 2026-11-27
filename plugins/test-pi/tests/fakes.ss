(import (tuna) (test) (test-runner) (processes) (json) (test-pi))

(define (ref object key) (let ([pair (assoc key object)]) (and pair (cdr pair))))

(define (version)
  (let-values ([(status out err) (processes:run "pi" '("--version"))]) (utf8->string out)))

(define (start-pi session-id lines)
  (let* ([seen '()]
         [p (processes:start "pi" (list "--mode" "rpc" "--session-id" session-id)
              (processes:line-receiver 0 (lambda (line end) (unless (eof-object? line) (set! seen (cons (string->json line) seen)))))
              (lambda (status) (void))
              (processes:options [separate-stderr #t]))])
    (for-each (lambda (l) (processes:send! p (string-append (json->string l) "\n"))) lines)
    (values p (lambda () (reverse seen)))))

(test "pi on the PATH is the fake, whose version is 1.5.0 unless set"
  (check-equal? "1.5.0\n" (version))
  (test-pi:set-version! "1.4.2")
  (check-equal? "1.4.2\n" (version))
  (test-pi:set-version! "1.5.0"))

(test "a fake answers Pi's usual requests by itself, gives its arguments and folder, and records what it was sent"
  (let-values ([(p said) (start-pi "s-1" '((("id" . "1") ("type" . "get_state")) (("id" . "2") ("type" . "get_entries"))
                                            (("id" . "3") ("type" . "get_entries") ("since" . "nowhere"))))])
    (let ([f (test-pi:fake p)])
      (test-runner:wait-until (lambda () (= 3 (length (said)))))
      (check-equal? '("--mode" "rpc" "--session-id" "s-1") (test-pi:arguments f))
      (check-equal? (getenv "HOME") (test-pi:folder f))
      (check-equal? '("get_state" "get_entries" "get_entries") (test-pi:request-types f))
      (check-equal? '(#t #t #f) (map (lambda (r) (ref r "success")) (said)))
      (check-equal? "s-1" (ref (ref (car (said)) "data") "sessionId"))
      (check-equal? "no such entry" (ref (caddr (said)) "error"))
      (processes:stop! p))))

(test "a held request waits for the test, which answers or refuses it; said records come out in order; an exit ends the fake with its status and error text"
  (let-values ([(p said) (start-pi "s-2" '())])
    (let ([f (test-pi:fake p)])
      (test-pi:hold! f "prompt")
      (processes:send! p "{\"id\":\"9\",\"type\":\"prompt\",\"message\":\"Hi\"}\n")
      (let ([r (test-pi:take-held! f "prompt")])
        (check-equal? "Hi" (ref r "message"))
        (test-pi:refuse! f r "busy"))
      (test-pi:say! f (test-pi:event "agent_start") (test-pi:event "agent_end"))
      (test-runner:wait-until (lambda () (= 3 (length (said)))))
      (check-equal? '("response" "agent_start" "agent_end") (map (lambda (r) (ref r "type")) (said)))
      (test-pi:exit! f 3 "gone\n")
      (test-runner:wait-until (lambda () (processes:status p)))
      (check-equal? 3 (processes:status p))
      (check-equal? "gone\n" (utf8->string (processes:error-output p))))))

(test "a fake started on a session saved earlier has its entries"
  (test-pi:save-session! "s-3" (list (test-pi:entry "u" #f (test-pi:user-message "Hi"))))
  (let-values ([(p said) (start-pi "s-3" '((("id" . "1") ("type" . "get_entries"))))])
    (test-runner:wait-until (lambda () (= 1 (length (said)))))
    (check-equal? '("u") (map (lambda (e) (ref e "id")) (vector->list (ref (ref (car (said)) "data") "entries"))))
    (processes:stop! p)))
