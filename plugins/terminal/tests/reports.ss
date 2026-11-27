(import (tuna) (test) (test-runner) (test-user) (options) (hooks) (ask) (buffers) (views) (web) (processes)
        (terminal) (terminal-test))

(define client (test-user:client))

(define (colors! background)
  (web:post-input! client
    `(("type" . "terminal-colors") ("foreground" . "#101010") ("background" . ,background) ("cursor" . "#ff0000")
      ("palette" . #("#000000" "#aa0000" "#00aa00" "#aaaa00" "#0000aa" "#aa00aa" "#00aaaa" "#aaaaaa"
                     "#555555" "#ff5555" "#55ff55" "#ffff55" "#5555ff" "#ff55ff" "#55ffff" "#ffffff"))))
  (test-user:settle))

(define (screen-element)
  (test-user:settle)
  (car (test-user:elements (test-user:screen) "terminal-screen")))

(define (shown-reader n . setup)
  (let ([r (apply terminal-test:reader n setup)])
    (terminal-test:show! r)
    r))

(test "the plugin answers the program's colour queries with the colours of the device whose input reached the terminal last"
  (colors! "#fafafa")
  (check-equal? "1b 5d 31 31 3b 72 67 62 3a 66 61 66 61 2f 66 61"
                (terminal-test:read-by (terminal-test:reader 16 "printf '\\033]11;?\\007'; ")))
  (check-equal? "1b 5b 3f 39 39 37 3b 32 6e" (terminal-test:read-by (terminal-test:reader 9 "printf '\\033[?996n'; "))))

(test "a program that asked is told when the colours change"
  (let ([r (terminal-test:reader 9 "printf '\\033[?2031h'; ")])
    (colors! "#101010")
    (check-equal? "1b 5b 3f 39 39 37 3b 31 6e" (terminal-test:read-by r))))

(test "a program that asked is told when a view showing it becomes the selected view, or stops being it"
  (let ([r (shown-reader 6 "printf '\\033[?1004h'; ")])
    (terminal-test:show! (buffers:make "notes" ""))
    (check-equal? "1b 5b 49 1b 5b 4f" (terminal-test:read-by r))))

(test "while a program takes the mouse, a click on its screen is a mouse report at the cell clicked"
  (let ([r (shown-reader 18 "printf '\\033[?1000h\\033[?1006h'; ")])
    (test-user:click-cell! (screen-element) 2 0 "<mouse-1>")
    (check-equal? "1b 5b 3c 30 3b 33 3b 31 4d 1b 5b 3c 30 3b 33 3b 31 6d" (terminal-test:read-by r))))

(test "a press's moves report the button held until its release"
  (let ([r (shown-reader 21 "printf '\\033[?1002h\\033[?1006h'; ")])
    (test-user:drag-cells! (screen-element) 30 4 31 4 "<drag-mouse-3>")
    (check-equal? "1b 5b 3c 32 3b 33 31 3b 35 4d 1b 5b 3c 33 34 3b 33 32 3b 35 4d" (terminal-test:read-by r))))

(test "every button and the wheel are reported, with their modifiers"
  (let ([r (shown-reader 18 "printf '\\033[?1000h\\033[?1006h'; ")])
    (test-user:click-cell! (screen-element) 4 2 "<mouse-2>")
    (check-equal? "1b 5b 3c 31 3b 35 3b 33 4d 1b 5b 3c 31 3b 35 3b 33 6d" (terminal-test:read-by r)))
  (let ([r (shown-reader 20 "printf '\\033[?1000h\\033[?1006h'; ")])
    (test-user:wheel! (screen-element) 0 0 "C-<wheel-up>")
    (test-user:wheel! (screen-element) 1 1 "<wheel-down>")
    (check-equal? "1b 5b 3c 38 30 3b 31 3b 31 4d 1b 5b 3c 36 35 3b 32 3b 32 4d" (terminal-test:read-by r))))

(test "on the alternate screen, xterm's alternate scroll mode is on, and the wheel sends the arrow keys"
  (let ([r (shown-reader 6 "printf '\\033[?1049h'; ")])
    (test-user:wheel! (screen-element) 0 0 "<wheel-up>")
    (test-user:wheel! (screen-element) 0 0 "<wheel-down>")
    (check-equal? "1b 5b 41 1b 5b 42" (terminal-test:read-by r))))

(test "with Shift a click names the character, and the editing commands bound under the screen's keymap run"
  (let ([r (shown-reader 1 "printf '\\033[?1000h'; ")])
    (let ([at (+ (terminal-test:position-of r "ready") 2)])
      (test-user:click! (terminal-test:view) at "S-<mouse-1>")
      (check-equal? at (views:point (terminal-test:view))))
    (buffers:kill! r)))

(define killed #f)

(test "what programs report runs the hooks, with plain data, after the output that carried it is applied"
  (let ([reports '()])
    (define (note! . x) (set! reports (cons x reports)))
    (hooks:add! terminal:bell (lambda (t) (note! 'bell)))
    (hooks:add! terminal:notification (lambda (t title body) (note! 'notification title body)))
    (hooks:add! terminal:progress (lambda (t state percent) (note! 'progress state percent)))
    (hooks:add! terminal:program-status (lambda (t report) (note! 'status report)))
    (hooks:add! terminal:screen-changed (lambda (t) (note! 'screen-changed (buffers:name t))))
    (let ([t (terminal-test:shell!)])
      (test-user:settle)
      (set! reports '())
      (terminal:send! t "printf '\\a\\e]9;Done\\a\\e]777;notify;Build;It passed\\a\\e]9;4;1;40\\a\\e]7501;state=blocked:kind=permission:app=claude\\a'\r")
      (let ([expected '((screen-changed "*terminal*") (bell) (notification "" "Done") (notification "Build" "It passed")
                        (progress set 40) (status ((state . blocked) (kind . permission) (app . "claude")))
                        (screen-changed "*terminal*"))])
        (guard (c [(and (who-condition? c) (eq? 'test-runner:wait-until (condition-who c)))
                   (check-equal? expected (reverse reports))])
          (test-runner:wait-until (lambda () (equal? expected (reverse reports))))))
      (set! killed t))))

(test "killing a terminal whose shell runs a job asks first"
  (let ([p (terminal:process killed)] [asked '()])
    (terminal:send! killed "sleep 30\r")
    (test-runner:wait-until (lambda () (not (eqv? (processes:foreground-group p) (processes:pid p)))))
    (options:set! ask:y-or-n-reader (lambda (question) (set! asked (cons question asked)) #f))
    (check-equal? #f (buffers:kill! killed))
    (check-equal? '("*terminal* runs a job; kill it and the job? ") asked)
    (options:set! ask:y-or-n-reader (lambda (question) #t))
    (check-equal? #t (buffers:kill! killed))
    (options:unset! ask:y-or-n-reader)))
