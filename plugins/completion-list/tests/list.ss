(import (tuna) (test) (test-user) (test-runner) (options) (hooks) (faces) (modes) (buffers) (views) (minibuffer) (completion)
        (completion-list) (completion-test sessions) (minibuffer-test reading))

(define (quit! r)
  (test-user:press! "C-g")
  (check-raises cancelled? (minibuffer-test/reading:result r)))

(define (read-words words)
  (minibuffer-test/reading:start!
    (lambda () (completion:read "Word: " (list (completion:source (candidates (list->vector words)))) #f))))

(define (frame)
  (let ([frames (test-user:elements (test-user:screen) "completion-list")])
    (check-equal? 1 (length frames))
    (car frames)))

(define (count-text)
  (let ([count (car (test-user:elements (frame) "completion-list-count"))])
    (apply string-append (filter string? (cdr count)))))

(define (count-line)
  (let ([count (car (test-user:elements (frame) "completion-list-count"))])
    (test-user:element-text count)))

(define (frame-lines)
  (let* ([style (test-user:element-attribute (frame) "style")] [key "--completion-list-lines:"])
    (and (> (string-length style) (string-length key))
         (string=? key (substring style 0 (string-length key)))
         (string->number (substring style (string-length key) (string-length style))))))

(define (rows-view-element)
  (car (test-user:elements-with (frame) "data-view")))

(define (drawn-rows) (map test-user:element-text (test-user:elements (rows-view-element) "completion-text")))

(define (session) (completion-test/sessions:session))

(test "a read's list sits in its prompt's content below the input, its count above the rows' view and outside it; the read's end takes both away"
  (let ([r (read-words '("alpha" "apple" "banana"))])
    (let ([content (car (test-user:elements (test-user:screen) "minibuffer-content"))])
      (check-equal? 1 (length (test-user:elements content "completion-list"))))
    (check-equal? "1/3" (count-line))
    (check-equal? (symbol->string faces:shadow)
                  (test-user:element-attribute (car (test-user:elements (frame) "completion-list-count")) "data-face"))
    (check-equal? '() (test-user:elements (rows-view-element) "completion-list-count"))
    (check-equal? '("alpha" "apple" "banana") (drawn-rows))
    (test-user:press! "C-n")
    (check-equal? "2/3" (count-line))
    (test-user:type! "ban")
    (check-equal? "1/1" (count-line))
    (quit! r)
    (check-equal? '() (test-user:elements (test-user:screen) "completion-list"))
    (check-equal? '() (filter (lambda (b) (eq? completion-list:mode (modes:major-mode b))) (buffers:all)))))

(test "the count shows 0 while nothing is selected, and … while a source works"
  (options:set! completion:read-preselect 'none)
  (let ([r (read-words '("alpha" "apple"))])
    (check-equal? "0/2" (count-line))
    (quit! r))
  (options:unset! completion:read-preselect)
  (let* ([feed #f]
         [r (minibuffer-test/reading:start!
              (lambda ()
                (completion:read "Item: "
                  (list (completion:source (stream (lambda (emit) (set! feed emit) (lambda (prefix) (void)))) (in-order)))
                  #f)))])
    (feed (vector "one" "two"))
    (test-runner:wait-until (lambda () (= 2 (completion:matches-count (completion:session-matches (session))))))
    (test-user:settle)
    (check-equal? "1/2 …" (count-line))
    (feed 'done)
    (completion-test/sessions:wait-matches (session))
    (test-user:settle)
    (check-equal? "1/2" (count-line))
    (quit! r)))

(test "a narrowed read names the sources it shows after the count"
  (let ([r (minibuffer-test/reading:start!
             (lambda ()
               (completion:read-or-input "? "
                 (list (completion:source (candidates (vector "notes" "todo")) (title "Buffers") (narrow #\b))
                       (completion:source (candidates (vector "notes.txt" "init.ss")) (title "Files") (narrow #\f)))
                 #f)))])
    (check-equal? '() (test-user:elements (frame) "completion-list-narrowed"))
    (test-user:press! "f SPC")
    (check-equal? '("Files") (map test-user:element-text (test-user:elements (frame) "completion-list-narrowed")))
    (check-equal? "1/2" (count-text))
    (quit! r)))

(test "the list is at most completion-list:lines lines tall, and every match is a row"
  (options:set! completion-list:lines 2)
  (let ([r (read-words '("a1" "a2" "a3" "a4"))])
    (check-equal? 2 (frame-lines))
    (check-equal? '("a1" "a2" "a3" "a4") (drawn-rows))
    (test-user:press! "C-n C-n C-n")
    (check-equal? "a4" (completion-test/sessions:selected-text (session)))
    (test-user:press! "RET")
    (check-equal? "a4" (minibuffer-test/reading:result r)))
  (options:unset! completion-list:lines))

(define (read-from-a1)
  (minibuffer-test/reading:start!
    (lambda ()
      (minibuffer:call-with-setup (lambda (p) (minibuffer:set-input! p "a1"))
        (lambda () (completion:read "Word: " (list (completion:source (candidates (vector "a1" "a2" "a3" "a4")))) #f))))))

(test "the list grows as rows arrive and keeps its height as the matches narrow, so its first height counts only the input the user sees"
  (let ([r (read-from-a1)])
    (completion-test/sessions:wait-matches (session))
    (test-user:settle)
    (check-equal? 1 (frame-lines))
    (test-user:press! "DEL DEL")
    (check-equal? 4 (frame-lines))
    (test-user:type! "z")
    (check-equal? (list 0 4) (list (completion:matches-count (completion:session-matches (session))) (frame-lines)))
    (quit! r)))

(test "with completion-list:fixed-height? the list is completion-list:lines tall from its first draw"
  (options:set! completion-list:fixed-height? #t)
  (let ([r (read-from-a1)])
    (completion-test/sessions:wait-matches (session))
    (test-user:settle)
    (check-equal? (completion-list:lines) (frame-lines))
    (quit! r))
  (options:unset! completion-list:fixed-height?))

(test "the list's keys move the selection: C-n, C-p, the arrows, M-< and M->; M-} and M-{ move between groups"
  (let ([r (minibuffer-test/reading:start!
             (lambda ()
               (completion:read "? "
                 (list (completion:source (candidates (vector "a1" "a2" "b1" "b2")) (in-order)
                         (group (lambda (text value) (substring text 0 1)))))
                 #f)))]
        [selected (lambda () (completion-test/sessions:selected-text (session)))])
    (for-each
      (lambda (key expected)
        (test-user:press! key)
        (check-equal? expected (selected)))
      '("<down>" "C-n" "<up>" "C-p" "M->" "M-<" "M-}" "M-{")
      '("a2" "b1" "a2" "a1" "b2" "a1" "b1" "a1"))
    (quit! r)))

(test "C-v and M-v move the selection by completion-list:lines rows, and M-w copies the selected candidate's text"
  (options:set! completion-list:lines 3)
  (let ([r (read-words (map (lambda (i) (format "row ~2,'0d" i)) (iota 10)))]
        [selected (lambda () (completion-test/sessions:selected-text (session)))])
    (test-user:press! "C-v")
    (check-equal? "row 03" (selected))
    (test-user:press! "<next>")
    (check-equal? "row 06" (selected))
    (test-user:press! "M-v")
    (check-equal? "row 03" (selected))
    (test-user:press! "<prior>")
    (check-equal? "row 00" (selected))
    (quit! r))
  (options:unset! completion-list:lines))

(test "a session that is no read, such as one at point, gets no list"
  (let ([region (lambda ()
                  (let ([p (views:point (views:current))])
                    (and (> p 2) (completion:region (- p 2) p (list (completion:source (candidates (vector "alpha" "almond"))))))))])
    (hooks:add! completion:find-region region)
    (test-user:show! "al|")
    (test-user:press! "C-M-i")
    (check (session))
    (check-equal? '() (test-user:elements (test-user:screen) "completion-list"))
    (test-user:press! "C-g")
    (hooks:remove! completion:find-region region)))
