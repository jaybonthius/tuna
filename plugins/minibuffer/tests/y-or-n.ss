(import (tuna) (test) (test-user) (options) (keys) (commands) (modes) (buffers) (views) (layout) (editing) (echo-area) (ask) (minibuffer) (minibuffer-test reading) (minibuffer-test screen))

(define (asking) (minibuffer-test/reading:start! (lambda () (minibuffer:ask-y-or-n "Save it? "))))

(define (run command) (views:call-with-view (layout:selected-view) (lambda () (commands:run command))))

(test "a y-or-n question asks with (y or n); y, Y and SPC answer yes, n, N, DEL and <delete> answer no; the answer is echoed"
  (let ([r (asking)])
    (check-equal? '("Save it? (y or n) ") (minibuffer-test/screen:questions))
    (minibuffer-test/reading:quit! r))
  (for-each
    (lambda (key answer)
      (let ([r (asking)])
        (test-user:press! key)
        (check-equal? answer (minibuffer-test/reading:result r))
        (check-equal? (if answer "Save it? (y or n) y" "Save it? (y or n) n") (echo-area:current-message))))
    '("y" "Y" "SPC" "n" "N" "DEL" "<delete>")
    '(#t #t #t #f #f #f #f)))

(test "another printing key clears the input and says Please answer y or n, and the question waits"
  (let ([r (asking)])
    (test-user:type! "q")
    (check-equal? 'waiting (minibuffer-test/reading:result r))
    (check-equal? "" (minibuffer-test/reading:input))
    (check-equal? " [Please answer y or n]" (minibuffer-test/screen:bracket))
    (test-user:press! "y")
    (check-equal? #t (minibuffer-test/reading:result r))))

(test "RET, an input set to y, or an exit with y do not answer a y-or-n question"
  (let ([r (asking)])
    (test-user:press! "RET")
    (check-equal? 'waiting (minibuffer-test/reading:result r))
    (minibuffer:set-input! (minibuffer-test/reading:prompt) "y")
    (test-user:press! "RET")
    (check-equal? 'waiting (minibuffer-test/reading:result r))
    (minibuffer:exit! (minibuffer-test/reading:prompt) "y")
    (test-user:settle)
    (check-equal? 'waiting (minibuffer-test/reading:result r))
    (test-user:type! "y")
    (check-equal? #t (minibuffer-test/reading:result r))))

(test "the question's keymap is a table the user binds in"
  (keys:bind! minibuffer:y-or-n-keymap "j" minibuffer:answer-yes)
  (let ([r (asking)])
    (test-user:press! "j")
    (check-equal? #t (minibuffer-test/reading:result r)))
  (keys:unbind! minibuffer:y-or-n-keymap "j"))

(test "the mode is on while point is in a y-or-n question, so its commands are offered there, and run by name they answer"
  (let ([r (asking)])
    (views:call-with-view (layout:selected-view)
      (lambda ()
        (check-equal? (list #t #t) (list (minibuffer:y-or-n-mode) (modes:on? minibuffer:y-or-n-mode (layout:selected-view))))
        (check-equal? '(#t #t) (map (lambda (c) (modes:command-for-view? c (layout:selected-view))) (list minibuffer:answer-yes minibuffer:answer-no)))))
    (run minibuffer:answer-no)
    (test-user:settle)
    (check-equal? #f (minibuffer-test/reading:result r))))

(test "in another prompt and in another buffer's view the mode is off; with no question waiting the answers raise"
  (let ([r (minibuffer-test/reading:start! (lambda () (minibuffer:read "Name: ")))]
        [elsewhere (views:make (buffers:make (buffers:free-name "notes") "one"))])
    (views:call-with-view (layout:selected-view)
      (lambda ()
        (check-equal? '(#f #f) (list (minibuffer:y-or-n-mode) (modes:command-for-view? minibuffer:answer-yes (layout:selected-view))))))
    (check-equal? '(#f #f) (list (modes:on? minibuffer:y-or-n-mode elsewhere) (modes:command-for-view? minibuffer:answer-no elsewhere)))
    (check-equal? '("no y-or-n question waits") (minibuffer-test/screen:report-messages (lambda () (run minibuffer:answer-yes))))
    (minibuffer-test/reading:quit! r)))

(test "run where point is in no y-or-n question, an answer answers the innermost one, and the prompt holding point stays"
  (let* ([asked (asking)] [named (minibuffer-test/reading:start! (lambda () (minibuffer:read "Name: ")))])
    (views:call-with-view (layout:selected-view) (lambda () (check-equal? #f (minibuffer:y-or-n-mode))))
    (run minibuffer:answer-yes)
    (test-user:settle)
    (check-equal? #t (minibuffer-test/reading:result asked))
    (check-equal? 'waiting (minibuffer-test/reading:result named))
    (test-user:type! "y")
    (check-equal? "y" (minibuffer-test/reading:input))
    (test-user:press! "RET")
    (check-equal? "y" (minibuffer-test/reading:result named))))

(test "a yes-or-no question asks again on another answer, saying Please answer yes or no"
  (let ([r (minibuffer-test/reading:start! (lambda () (minibuffer:ask-yes-or-no "Delete it? ")))])
    (check-equal? '("Delete it? (yes or no) ") (minibuffer-test/screen:questions))
    (test-user:type! "maybe")
    (test-user:press! "RET")
    (test-user:settle)
    (check-equal? 'waiting (minibuffer-test/reading:result r))
    (check-equal? "" (minibuffer-test/reading:input))
    (check-equal? " [Please answer yes or no]" (minibuffer-test/screen:bracket))
    (test-user:type! "yes")
    (test-user:press! "RET")
    (check-equal? #t (minibuffer-test/reading:result r))))

(test "minibuffer answers ask's y-or-n and yes-or-no questions, and ask:yes-or-no-reader set to ask-y-or-n takes one key"
  (let ([r (minibuffer-test/reading:start! (lambda () (ask:y-or-n? "Save it? ")))])
    (test-user:type! "n")
    (check-equal? #f (minibuffer-test/reading:result r)))
  (let ([r (minibuffer-test/reading:start! (lambda () (ask:yes-or-no? "Delete it? ")))])
    (test-user:type! "yes")
    (test-user:press! "RET")
    (check-equal? #t (minibuffer-test/reading:result r)))
  (options:set! ask:yes-or-no-reader minibuffer:ask-y-or-n)
  (let ([r (minibuffer-test/reading:start! (lambda () (ask:yes-or-no? "Delete it? ")))])
    (test-user:type! "y")
    (check-equal? #t (minibuffer-test/reading:result r)))
  (options:unset! ask:yes-or-no-reader))
