(import (tuna) (test) (test-runner) (options) (web) (buffers) (modes) (jsonrpc) (servers))

(define (starts? prefix line)
  (and (>= (string-length line) (string-length prefix)) (string=? prefix (substring line 0 (string-length prefix)))))

(define (ends? suffix line)
  (let ([n (string-length line)] [k (string-length suffix)])
    (and (>= n k) (string=? suffix (substring line (- n k) n)))))

(define c (servers:start "fake" (jsonrpc:handlers)))

(test "each connection logs what it sent and received, one line each, in a silent buffer in jsonrpc:events-mode"
  (check-equal? '(("a" . 1)) (jsonrpc:request c "echo" '(("a" . 1))))
  (check-equal? '("--> {\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"echo\",\"params\":{\"a\":1}}"
                  "<-- {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"a\":1}}")
    (servers:log-lines c))
  (let ([events (jsonrpc:events-buffer c)])
    (check-equal? "*fake events*" (buffers:name events))
    (check-equal? jsonrpc:events-mode (modes:major-mode events))
    (check (buffers:silent? events))
    (check-equal? events (jsonrpc:events-buffer c))))

(test "stray output, a body that is not JSON and the program's standard error are logged, and reading goes on"
  (check-equal? "written" (jsonrpc:request c "raw" '(("texts" . #("starting up\n" "half a line")))))
  (check-equal? '#(2) (jsonrpc:request c "echo" '#(2)))
  (check-equal? "written" (jsonrpc:request c "raw" '(("texts" . #("Content-Length: 4\r\n\r\nnope")))))
  (check-equal? "written" (jsonrpc:request c "stderr" '(("text" . "warning: one\nwarning: two\n"))))
  (test-runner:wait-until (lambda () (member "stderr: warning: two" (servers:log-lines c))))
  (check-equal? '("stray: starting up" "stray: half a line" "not JSON: unexpected #\\o at position 1" "stderr: warning: one" "stderr: warning: two")
    (filter (lambda (line) (not (or (starts? "--> " line) (starts? "<-- " line)))) (servers:log-lines c))))

(test "a frame error is logged and the connection's first reported; output that mentions a header costs only the frame it overlaps"
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (check-equal? "written" (jsonrpc:request c "raw" '(("texts" . #("Content-Length: 99999999999\r\n\r\n")))))
    (check-equal? '(timeout "raw")
      (servers:raised (lambda () (jsonrpc:request c "raw" '(("texts" . #("debug: sent Content-Length: 5 bytes\n"))) 0.5))))
    (check-equal? '#(3) (jsonrpc:request c "echo" '#(3)))
    (advice-remove! report keep)
    (check-equal? '("fake broke the framing: frame of 99999999999 bytes is longer than frame-max-length, 268435456; its events log has the rest")
      (map condition-message reported)))
  (check-equal? '("frame error: frame of 99999999999 bytes is longer than frame-max-length, 268435456"
                  "frame error: Content-Length \" 5 bytes\" is not a byte count")
    (filter (lambda (line) (starts? "frame error: " line)) (servers:log-lines c)))
  (check (member "<-- {\"jsonrpc\":\"2.0\",\"id\":6,\"result\":\"written\"}" (servers:log-lines c)))
  (check (exists (lambda (line) (and (starts? "stray: " line) (ends? "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":\"written\"}" line)))
                 (servers:log-lines c)))
  (check (jsonrpc:running? c)))

(test "an answer no request waits for is logged with its id"
  (check-equal? "written"
    (jsonrpc:request c "raw" '(("texts" . #("Content-Length: 36\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":99,\"result\":1}")))))
  (check (member "no request waits for: 99" (servers:log-lines c))))

(test "jsonrpc:events-mode derives from special, and nothing reverts a log"
  (check (modes:derived? jsonrpc:events-mode modes:special))
  (check-equal? "nothing reverts this buffer"
    (guard (e [(error? e) (condition-message e)])
      (buffers:with-buffer (jsonrpc:events-buffer c) (buffers:revert-buffer)))))

(test "a log keeps at most jsonrpc:events-log-size characters, the oldest lines going first; with 0 nothing is logged"
  (options:set! jsonrpc:events-log-size 120)
  (let ([small (servers:start "small" (jsonrpc:handlers))])
    (for-each (lambda (n) (jsonrpc:request small "echo" (vector n))) '(1 2 3 4))
    (check-equal? '("--> {\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"echo\",\"params\":[4]}" "<-- {\"jsonrpc\":\"2.0\",\"id\":4,\"result\":[4]}")
      (servers:log-lines small))
    (check (<= (string-length (servers:log-text small)) 120))
    (jsonrpc:stop! small))
  (options:set! jsonrpc:events-log-size 0)
  (let ([none (servers:start "none" (jsonrpc:handlers))])
    (check-equal? '#(1) (jsonrpc:request none "echo" '#(1)))
    (check-equal? "" (servers:log-text none))
    (options:set! jsonrpc:events-log-size 2000)
    (check-equal? '#(2) (jsonrpc:request none "echo" '#(2)))
    (check-equal? '("--> {\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"echo\",\"params\":[2]}" "<-- {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":[2]}")
      (servers:log-lines none))
    (jsonrpc:stop! none))
  (options:unset! jsonrpc:events-log-size))
