(import (echo-area-test beneath) (tuna) (test) (test-user) (test-runner) (options) (faces) (buffers) (document) (layout) (timers) (editing) (echo-area) (ask)
        (minibuffer) (minibuffer-test reading) (minibuffer-test screen))

(define (layout-datums) (document:datums (buffers:document layout:buffer)))

(define (done? task) (eq? (task-state task) 'done))

(define (prompts-drawn) (test-user:elements (test-user:screen) "minibuffer-prompt"))

(test "twenty nested prompts quit in a scrambled order each raise a quit, and the prompts and the layout end as they began"
  (test-user:settle)
  (let* ([before (layout-datums)]
         [readings (map (lambda (i) (minibuffer-test/reading:start! (lambda () (minibuffer:read (format "Q~a: " i))))) (iota 20))])
    (check-equal? '("[20] ") (map test-user:element-text (test-user:elements (test-user:screen) "minibuffer-depth")))
    (for-each (lambda (i) (cancel-task (minibuffer-test/reading:task (list-ref readings i))))
      '(7 0 19 3 12 5 18 1 9 14 2 16 6 11 4 17 8 13 10 15))
    (test-runner:wait-until (lambda () (not (exists minibuffer-test/reading:waiting? readings))))
    (test-user:settle)
    (for-each (lambda (r) (check-raises cancelled? (minibuffer-test/reading:result r))) readings)
    (check-equal? #f (minibuffer:current-prompt))
    (check-equal? '() (prompts-drawn))
    (check-equal? before (layout-datums))))

(define (storm! read)
  (let* ([stop #f]
         [askers (map (lambda (i)
                        (spawn-task
                          (lambda (restore)
                            (let loop ([n 0])
                              (unless (or stop (= n 200))
                                (guard (c [(cancelled? c) #f]) (read i))
                                (loop (+ n 1)))))))
                      (iota 3))]
         [quitter (spawn-task
                    (lambda (restore)
                      (let loop ([n 0])
                        (unless (= n 300)
                          (for-each cancel-task askers)
                          (echo-area:message! "Quitting")
                          (timers:sleep 0.001)
                          (loop (+ n 1))))))])
    (test-runner:wait-until (lambda () (done? quitter)))
    (set! stop #t)
    (for-each cancel-task askers)
    (test-runner:wait-until (lambda () (for-all done? askers)))
    (test-user:settle)))

(test "a storm of quits while prompts start and end leaves no prompt behind and the layout whole"
  (let ([before (layout-datums)])
    (storm! (lambda (i) (minibuffer:read "Storm: ")))
    (check-equal? #f (minibuffer:current-prompt))
    (check-equal? '() (prompts-drawn))
    (check-equal? before (layout-datums))))

(test "quits landing while prompts start, show messages and end leave the echo area shown and working"
  (storm! (lambda (i)
            (minibuffer:call-with-setup
              (lambda (p) (echo-area:message! "Setup ~a" i) (minibuffer:message! p "Own"))
              (lambda () (minibuffer:read "Storm: ")))))
  (check-equal? (list #f #f #t) (list (minibuffer:current-prompt) (echo-area:hidden?) (minibuffer-test/screen:echo-drawn?)))
  (echo-area:message! "Calm")
  (check-equal? "Calm" (echo-area:current-message)))

(define (lines-logged-from-threads)
  (let loop ([chars (string->list (minibuffer-test/reading:buffer-text (buffers:find "*Messages*")))] [line '()] [n 0])
    (cond
      [(null? chars) n]
      [(char=? (car chars) #\newline)
       (loop (cdr chars) '() (if (and (pair? line) (char=? (car (last-pair line)) #\t)) (+ n 1) n))]
      [else (loop (cdr chars) (cons (car chars) line) n)])))

(test "reports from four threads while a prompt waits are all logged, and the last shown is drawn after the input in its face"
  (options:set! echo-area:log-max 16384)
  (let ([r (minibuffer-test/reading:start! (lambda () (minibuffer:read "Name: ")))] [done 0] [done-mutex (make-mutex)])
    (echo-area-test/beneath:reports-during
      (lambda ()
        (for-each
          (lambda (i)
            (fork-task
              (lambda (restore)
                (do ([k 0 (+ k 1)]) ((= k 100))
                  (report (condition (make-error) (make-message-condition (format "t~a-~a" i k)))))
                (with-mutex done-mutex (set! done (+ done 1))))))
          '(0 1 2 3))
        (test-runner:wait-until (lambda () (with-mutex done-mutex (= done 4))))
        (test-user:settle)
        (check-equal? 400 (lines-logged-from-threads))
        (check-equal? #t (echo-area:hidden?))
        (check-equal? (list (string-append " [" (echo-area:current-message) "]")
                            (let ([face (echo-area:current-face)]) (and face (symbol->string face))))
          (list (minibuffer-test/screen:bracket) (minibuffer-test/screen:bracket-face)))
        (let* ([reported #f]
               [report-late
                (lambda (p)
                  (fork-task (lambda (restore) (report (condition (make-error) (make-message-condition "late"))) (set! reported #t)))
                  ;; The main thread spins inside the prompt's end, so the
                  ;; thread's report lands in the batch of the key that ends
                  ;; the prompt, after that key cleared the echo area.
                  (let ([until (+ (real-time) 30000)])
                    (let spin ()
                      (unless reported
                        (when (> (real-time) until) (error 'report-late "the thread did not report within 30 s"))
                        (spin)))))])
          (hooks:add! minibuffer:prompt-ended report-late)
          (test-user:press! "RET")
          (hooks:remove! minibuffer:prompt-ended report-late)
          (check-equal? "" (minibuffer-test/reading:result r))
          (check-equal? (list #f #f #t "late" faces:error)
            (list (minibuffer:current-prompt) (echo-area:hidden?) (minibuffer-test/screen:echo-drawn?) (echo-area:current-message)
                  (echo-area:current-face)))))))
  (options:unset! echo-area:log-max))

(test "reloading undo leaves the minibuffer, which does not import it"
  (let ([b (buffers:find " *Minibuf*")])
    (reload-modules! '((undo)))
    (test-user:settle)
    (check (eq? b (buffers:find " *Minibuf*")))
    (let ([r (minibuffer-test/reading:start! (lambda () (minibuffer:read "Name: ")))])
      (test-user:press! "RET")
      (check-equal? "" (minibuffer-test/reading:result r)))))

(test "reloading the minibuffer during a read quits the read, and the new instance's buffer, readers and prompts work"
  (let* ([old (module-owner '(minibuffer))] [old-buffer (buffers:find " *Minibuf*")]
         [outcome #f]
         [asker (spawn-task (lambda (restore) (guard (c [(cancelled? c) (set! outcome 'cancelled)]) (minibuffer:read "Name: "))))])
    (test-user:settle)
    (test-user:type! "abc")
    (check-equal? #t (echo-area:hidden?))
    (reload-modules! '((minibuffer)))
    (test-user:settle)
    (check-equal? 'cancelled outcome)
    (check-equal? '(#f #f) (list (owner-live? old) (buffers:live? old-buffer)))
    (check-equal? #f (echo-area:hidden?))
    (check (not (eq? (ask:line-reader) (options:default ask:line-reader))))
    (check (eq? (ask:number-reader) minibuffer:read-number))
    (check (minibuffer:buffer? (buffers:find " *Minibuf*"))))
  (let ([r (minibuffer-test/reading:start! (lambda () (minibuffer:read "Name: ")))])
    (test-user:type! "x")
    (test-user:press! "RET")
    (check-equal? "x" (minibuffer-test/reading:result r))
    (check-equal? "x" (car (minibuffer:history)))))
