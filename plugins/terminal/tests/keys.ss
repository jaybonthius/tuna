(import (tuna) (test) (test-user) (options) (ask) (buffers) (views) (keys) (commands) (editing)
        (buffers-test) (terminal) (terminal-test))

(define told '())

(options:set! ask:message-writer (lambda (text) (set! told (cons text told))))

(define client (test-user:client))

(define (bound-to-send-key? key) (eq? terminal:send-key (terminal-test:in-view (lambda () (keys:lookup client key)))))

(define (reported thunk)
  (map (lambda (c) (list (condition-who c) (condition-message c))) (buffers-test:reports-during thunk)))

(define (as-input char n)
  (lambda () (terminal-test:in-view (lambda () (keys:run-as-input client editing:self-insert n char)))))

(test "in semi-char mode keys go to the program, encoded as a terminal encodes them"
  (check-equal? "61 41 01 1b 61 1b 5b 41 1b 5b 31 3b 32 41 0d 09 7f 1b 07 c3 a9"
                (terminal-test:bytes-read '("a" "A" "C-a" "M-a" "<up>" "S-<up>" "RET" "TAB" "DEL" "ESC" "C-g" "é") 21))
  (check-equal? "1b 5b 31 35 7e 1b 5b 31 3b 35 44 1b 18" (terminal-test:bytes-read '("<f5>" "C-<left>" "C-M-x") 13)))

(test "C-c C-c and its kin send the keys Tuna keeps, and C-q sends the next key whatever its bindings"
  (check-equal? "03 1a 1c 04 18 03"
                (terminal-test:bytes-read '("C-c C-c" "C-c C-z" "C-c C-\\" "C-c C-d" "C-q C-x" "C-c C-q C-c") 6)))

(test "C-q reads the next key with no prompt, a quit key too"
  (let ([seen #f])
    (check-equal? "07"
      (terminal-test:bytes-read
        (list "C-q" (lambda () (set! seen (list (keys:reading client) (keys:reading-prompt client)))) "C-g")
        1))
    (check-equal? '("C-q" #f) seen)))

(test "the encoder follows the modes the program sets: application cursor keys, and the Kitty keyboard protocol"
  (check-equal? "1b 4f 41" (terminal-test:bytes-read '("<up>") 3 "printf '\\033[?1h'; "))
  (check-equal? "1b 5b 31 33 3b 32 75 1b 5b 32 37 75" (terminal-test:bytes-read '("S-RET" "ESC") 12 "printf '\\033[>1u'; ")))

(define t (terminal:start '("sh" "-c" "sleep 30")))

(test "in semi-char mode C-x, C-h, C-u, M-x and M-: start Tuna's sequences, and Super keys are Tuna's"
  (terminal-test:show! t)
  (check-equal? '(#f #f #f #f #f #f #t #t #t)
                (map bound-to-send-key? '("C-x" "C-h" "C-u" "M-x" "M-:" "s-a" "C-M-x" "C-t" "q"))))

(test "S-<prior> and S-<next> scroll the view"
  (check (eq? views:scroll-down (terminal-test:in-view (lambda () (keys:lookup client "S-<prior>")))))
  (check (eq? views:scroll-up (terminal-test:in-view (lambda () (keys:lookup client "S-<next>"))))))

(test "char mode sends every key but Super keys and M-RET, which goes back to semi-char mode"
  (test-user:press! "C-c M-d")
  (check-equal? 'char (terminal-test:input-mode))
  (check-equal? '(#t #t #t #f #f) (map bound-to-send-key? '("C-x" "C-c" "M-x" "s-a" "M-RET")))
  (test-user:press! "M-RET")
  (check-equal? 'semi-char (terminal-test:input-mode)))

(test "a command that leaves a region puts the terminal in copy mode, where keys are Tuna's; q leaves it, clearing the region"
  (set! told '())
  (test-user:press! "C-SPC")
  (check-equal? '("Mark set") told)
  (check-equal? 'copy (terminal-test:input-mode))
  (check (views:mark (terminal-test:view)))
  (check (eq? editing:move-beginning-of-line (terminal-test:in-view (lambda () (keys:lookup client "C-a")))))
  (test-user:press! "q")
  (check-equal? 'semi-char (terminal-test:input-mode))
  (check-equal? #f (views:mark (terminal-test:view))))

(test "a typed key leaves copy mode and goes to the program encoded, SPC as any other printing key"
  (check-equal? "1b 5b 39 37 75 1b 5b 33 32 75"
                (terminal-test:bytes-read '("C-c C-t" "a" "C-c C-t" "SPC") 10 "printf '\\033[>8u'; ")))

(test "C-c C-t enters copy mode and leaves it"
  (terminal-test:show! t)
  (test-user:press! "C-c C-t")
  (check-equal? 'copy (terminal-test:input-mode))
  (test-user:press! "C-c C-t")
  (check-equal? 'semi-char (terminal-test:input-mode)))

(test "outside a terminal the commands raise"
  (terminal-test:show! (buffers:make "notes" "hi\n"))
  (check-equal? '("C-c C-t is undefined")
                (map condition-message (buffers-test:reports-during (lambda () (test-user:press! "C-c C-t")))))
  (check-equal? '((terminal:copy-mode "not a terminal"))
                (reported (lambda () (terminal-test:in-view (lambda () (commands:run terminal:copy-mode)))))))

(test "input that is no key runs editing:self-insert, which a terminal remaps to send the character unencoded, under the Kitty protocol too"
  (check-equal? "61 c3 a9 c3 a9 41" (terminal-test:bytes-read (list (as-input #\a 1) (as-input #\é 2) (as-input #\A 1)) 6))
  (check-equal? "61" (terminal-test:bytes-read (list (as-input #\a 1)) 1 "printf '\\033[>31u'; ")))

(test "self-inserted text leaves copy mode first"
  (let ([s (terminal-test:shell!)])
    (terminal-test:show! s)
    (check (eq? terminal:self-insert (terminal-test:in-view (lambda () (keys:command-remapping client editing:self-insert)))))
    (test-user:press! "C-c C-t")
    ((as-input #\z 1))
    (check-equal? 'semi-char (terminal-test:input-mode))
    (terminal-test:wait-for s "$ z")
    (check-equal? '("$ z") (terminal-test:screen-lines s))
    (check-equal? '((terminal:self-insert "no character was typed"))
                  (reported (lambda () (terminal-test:in-view (lambda () (commands:run terminal:self-insert 1 #f))))))))
