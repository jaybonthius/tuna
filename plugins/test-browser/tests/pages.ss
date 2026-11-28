(import (tuna) (test) (test-browser) (test-user) (test-runner) (web) (keys) (views) (commands) (buffers) (ui) (cdp) (cdp page)
        (layout) (editing) (echo-area) (minibuffer) (command-picker) (completion))

(define page (test-browser:open))

(define waiting #f)

(commands:define-command (wait-for-ever)
  "Pauses until cancelled."
  (guard (e [(cancelled? e) (set! waiting (list 'cancelled (cancelled-reason e)))])
    (set! waiting 'paused)
    (suspend (lambda (resume) (void)))))

(keys:bind! keys:global "C-c w" wait-for-ever)

(define (texts selector) (test-browser:call (lambda () (map element-text (page-query page selector)))))

(define (reports-during thunk)
  (map (lambda (c) (if (cancelled? c) (list 'cancelled (cancelled-reason c)) (condition-message c))) (test-runner:reports-during thunk)))

(test "a page opened is a client of web, and has applied its first screen when open returns"
  (let* ([before (web:clients)] [other (test-browser:open)] [added (remp (lambda (c) (memq c before)) (web:clients))])
    (check-equal? 1 (length added))
    (check-equal? 1 (length (test-browser:call (lambda () (page-query other "#screen .layout-screen")))))
    (test-browser:close! other)
    (test-runner:wait-until (lambda () (not (memq (car added) (web:clients)))))))

(test "keys pressed in the page reach Tuna as a keyboard's, in Tuna's notation"
  (test-user:show! "one two|")
  (test-browser:press! page "C-a M-f C-k")
  (check-equal? "one|" (test-user:text))
  (test-browser:press! page "<left> <left> DEL C-e RET")
  (check-equal? "ne\n|" (test-user:text)))

(test "typed text reaches Tuna character by character, shifted characters and spaces included"
  (test-user:show! "|")
  (test-browser:type! page "Hi, there! (x_y)\nZ")
  (check-equal? "Hi, there! (x_y)\nZ|" (test-user:text)))

(test "the page has applied what Tuna drew by the time a press returns"
  (test-browser:press! page "M-x")
  (check-equal? '("M-x ") (texts ".minibuffer-question")))

(test "a quit key typed at a prompt is read as a key, whose binding ends the prompt; the page shows it gone and Quit"
  (check-equal? '((cancelled #f)) (reports-during (lambda () (test-browser:press! page "C-g"))))
  (check-equal? '() (texts ".minibuffer-question"))
  (check-equal? '("Quit") (texts ".echo-area-message")))

(test "a quit key the page marks as a quit stops a command paused for anything but input"
  (test-browser:press! page "C-c w")
  (check-equal? 'paused waiting)
  (test-browser:press! page "C-g")
  (check-equal? '(cancelled quit) waiting))

(test "wait-for-applied returns once the page shows what Tuna drew after a change made from Scheme"
  (echo-area:message! "Drawn")
  (test-browser:wait-for-applied page)
  (check-equal? '("Drawn") (texts ".echo-area-message")))

(define clicked 0)

(commands:define-command (note-click) "Counts a click." (set! clicked (+ clicked 1)))

;; A button's press runs nothing, so only the release can count.
(ui:define-button counter note-click)

(test "a click on an element reaches Tuna as a mouse's, and has run its command by the time click! returns"
  (layout:switch-to-buffer (buffers:make "buttons" (buffers:text '() "Press " (counter '() "here") "\n")))
  (test-browser:wait-for-applied page)
  (test-browser:click! page (car (test-browser:call (lambda () (page-query page ".ui-button")))))
  (check-equal? 1 clicked))

(test "a key no keyboard has, a click on what is no element of the page, and a page test-browser did not open, raise"
  (check-raises assertion-violation? (test-browser:press! page "<mouse-1>"))
  (check-raises assertion-violation? (test-browser:click! page 'element))
  (check-raises assertion-violation? (test-browser:press! 'page "a"))
  (check-raises assertion-violation? (test-browser:type! page 'text)))

(define (line-elements) (test-browser:call (lambda () (page-query page ".layout-view.selected .line"))))

(test "a button held while the pointer moves is released as a drag, as a hand's is"
  (test-user:show! "one\ntwo\nthree|")
  (test-browser:wait-for-applied page)
  (let ([lines (line-elements)])
    (test-browser:press-button! page (car lines))
    (let ([pressed (views:point (layout:selected-view))]
          [box (test-browser:call (lambda () (element-box (caddr lines))))])
      (test-browser:move-pointer! page (make-point (+ (rectangle-x box) 8) (+ (rectangle-y box) (/ (rectangle-height box) 2))))
      (test-browser:release-button! page)
      (check-equal? pressed (views:mark (layout:selected-view)))
      (check (> (views:point (layout:selected-view)) 8)))))

(test "drag! presses on an element and releases where it is told"
  (test-user:show! "one\ntwo\nthree|")
  (test-browser:wait-for-applied page)
  (let* ([lines (line-elements)] [box (test-browser:call (lambda () (element-box (cadr lines))))])
    (test-browser:drag! page (car lines) (make-point (+ (rectangle-x box) 8) (+ (rectangle-y box) (/ (rectangle-height box) 2)))))
  (check (<= (views:mark (layout:selected-view)) 4))
  (check (<= 4 (views:point (layout:selected-view)) 7)))

(test "a double click reaches Tuna as a press and a release, then a press and a release of two clicks"
  (set! clicked 0)
  (layout:switch-to-buffer (buffers:make "double" (buffers:text '() "Press " (counter '() "here") "\n")))
  (test-browser:wait-for-applied page)
  (test-browser:double-click! page (car (test-browser:call (lambda () (page-query page ".ui-button")))))
  (check-equal? 2 clicked))

(test "a second press while a button is held, and a move or release with none, raise"
  (test-user:show! "one|")
  (test-browser:wait-for-applied page)
  (test-browser:press-button! page (car (line-elements)))
  (check-raises assertion-violation? (test-browser:press-button! page (car (line-elements))))
  (test-browser:release-button! page)
  (check-raises assertion-violation? (test-browser:release-button! page))
  (check-raises assertion-violation? (test-browser:move-pointer! page (make-point 1 1))))

(test "a button released outside the window ends the press at the next move, as a drag"
  (test-user:show! "one\ntwo\nthree|")
  (test-browser:wait-for-applied page)
  (let ([lines (line-elements)])
    (test-browser:press-button! page (car lines))
    (let ([pressed (views:point (layout:selected-view))]
          [box (test-browser:call (lambda () (element-box (caddr lines))))])
      (test-browser:move-pointer! page (make-point (+ (rectangle-x box) 8) (+ (rectangle-y box) (/ (rectangle-height box) 2))))
      (test-browser:release-outside! page (make-point (+ (rectangle-x box) 8) (+ (rectangle-y box) (/ (rectangle-height box) 2))))
      (check-equal? pressed (views:mark (layout:selected-view)))
      (check (> (views:point (layout:selected-view)) 8))
      (check-raises assertion-violation? (test-browser:release-outside! page (make-point 1 1))))))
