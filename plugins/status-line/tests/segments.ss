(import (tuna) (test) (test-user) (layout) (views) (buffers) (document) (options) (tables) (modes)
        (status-line) (lighters) (cards) (status-line-test))

(define view status-line-test:view)
(define status status-line-test:status)
(define (text name) (status-line-test:segment-text (view) name))

(define plugin-segments
  (list status-line:modified status-line:buffer-name status-line:position status-line:percent-position
        status-line:region-size status-line:major-mode status-line:minor-modes))

(define (show! content)
  (let ([b (buffers:make (buffers:free-name "notes") content)])
    (views:set-buffer! (view) b)
    b))

(test "the plugin's seven segments show in their places, and each is its name, as a mode is"
  (check-equal? (map symbol->string plugin-segments) (status-line-test:segment-names (view)))
  (check-equal? '(status-line:modified status-line:position) (list status-line:modified status-line:position)))

(test "a status line is a footer marked with status-line:keymap, the right side's segments in their own element"
  (let ([f (status-line-test:footer (view))])
    (check-equal? (views:keymap-mark status-line:keymap) (test-user:element-attribute f "data-keymap"))
    (check-equal? '("status-line:major-mode" "status-line:minor-modes")
      (map (lambda (e) (test-user:element-attribute e "data-segment"))
           (test-user:elements (car (test-user:elements f "status-line-right")) "status-line-segment"))))
  (check-equal? #f (buffers:find " *status-line*")))

(test "the segments show the buffer's name, the line, where point is, no region, and the modes' lighters"
  (show! "Line one.\n\tTab and more.\n")
  (check-equal? (list (cons "status-line:modified" "") (cons "status-line:buffer-name" (buffers:name (views:buffer (view))))
                      (cons "status-line:position" "L1") (cons "status-line:percent-position" "Top")
                      (cons "status-line:region-size" "") (cons "status-line:major-mode" "Fundamental")
                      (cons "status-line:minor-modes" ""))
                (status (view))))

(test "with views:column-number on, the column follows the line, counting characters from the line's start, a tab as one"
  (show! "Line one.\n\tTab and more.\n")
  (options:set! views:column-number #t)
  (views:set-point! (view) 15)
  (check-equal? '("2:4" "56%") (list (text status-line:position) (text status-line:percent-position)))
  (views:set-point! (view) 22)
  (check-equal? '("2:11" "84%") (list (text status-line:position) (text status-line:percent-position)))
  (options:set! views:column-number #f))

(test "a modified buffer shows *, and the major mode's lighter and those of the minor modes on in the view follow"
  (let ([b (show! "one\n")])
    (buffers:replace! b 1 1 "x")
    (modes:set-major-mode lighters:script b)
    (views:with-view (view) (options:set-local! lighters:wrap #t))
    (check-equal? '("*" "Script" "Wrap") (map text (list status-line:modified status-line:major-mode status-line:minor-modes)))
    (buffers:set-modified! b #f)
    (check-equal? "" (text status-line:modified))))

(test "segments show the left side's, then the right side's, each in order; equal numbers keep the order first placed"
  (status-line:define-segment seg-a (show (lambda (view) "a")))
  (status-line:define-segment seg-b (show (lambda (view) "b")))
  (tables:set! status-line:segments seg-b (status-line:left 20))
  (tables:set! status-line:segments seg-a (status-line:left 20))
  (check-equal? (map symbol->string
                  (list status-line:modified status-line:buffer-name seg-b seg-a status-line:position status-line:percent-position
                        status-line:region-size status-line:major-mode status-line:minor-modes))
                (status-line-test:segment-names (view)))
  (tables:set! status-line:segments seg-b (status-line:right 0))
  (check-equal? (map symbol->string
                  (list status-line:modified status-line:buffer-name seg-a status-line:position status-line:percent-position
                        status-line:region-size seg-b status-line:major-mode status-line:minor-modes))
                (status-line-test:segment-names (view)))
  (tables:remove! status-line:segments seg-a)
  (tables:remove! status-line:segments seg-b))

(test "a value that is not a place goes to report once and its segment is not shown; a key that is not a segment is left out"
  (status-line:define-segment seg-a (show (lambda (view) "a")))
  (let ([reported (status-line-test:reports-during
                    (lambda ()
                      (tables:set! status-line:segments seg-a 'left)
                      (test-user:settle)
                      (test-user:settle)))])
    (check-equal? '((status-line:segments "not a place" (left)))
      (map (lambda (c) (list (condition-who c) (condition-message c) (condition-irritants c))) reported)))
  (check-equal? (map symbol->string plugin-segments) (status-line-test:segment-names (view)))
  (tables:set! status-line:segments car (status-line:left 1))
  (check-equal? (map symbol->string plugin-segments) (status-line-test:segment-names (view)))
  (tables:remove! status-line:segments car)
  (tables:remove! status-line:segments seg-a))

(define failing? #t)

(define (show-flaky view) (if failing? (car '()) "fine"))

(define (show-number view) 42)

(status-line:define-segment flaky (show show-flaky))
(status-line:define-segment number (show show-number))

(test "a show procedure that raises, or returns what is not HTML, a string or #f, goes to report once for its window, and the segment shows nothing until it shows again"
  (let ([reported (status-line-test:reports-during
                    (lambda ()
                      (tables:set! status-line:segments flaky (status-line:left 40))
                      (tables:set! status-line:segments number (status-line:left 41))
                      (test-user:settle)
                      (test-user:settle)))])
    (check-equal? (list 'car number) (map condition-who reported))
    (check-equal? '("a show procedure returned what is not HTML, a string or #f" (42))
      (list (condition-message (cadr reported)) (condition-irritants (cadr reported)))))
  (check-equal? '("" "") (list (text flaky) (text number)))
  (set! failing? #f)
  (check-equal? "fine" (text flaky))
  (set! failing? #t)
  (check-equal? '(car) (map condition-who (status-line-test:reports-during (lambda () (test-user:settle) (test-user:settle)))))
  (check-equal? "" (text flaky))
  (tables:remove! status-line:segments flaky)
  (tables:remove! status-line:segments number))

(test "a show procedure runs inside views:with-view of the window's view, with its buffer current, and the plugin's own can be advised"
  (status-line:define-segment current
    (show (lambda (v) (format "~a ~a" (eq? (views:current) v) (eq? (buffers:current) (views:buffer v))))))
  (tables:set! status-line:segments current (status-line:left 50))
  (check-equal? "#t #t" (text current))
  (tables:remove! status-line:segments current)
  (let ([shout (lambda (show view) (string-upcase (show view)))])
    (advice-add! status-line:show-buffer-name shout)
    (check-equal? (string-upcase (buffers:name (views:buffer (view)))) (text status-line:buffer-name))
    (advice-remove! status-line:show-buffer-name shout)))

(test "define-segment checks its clauses where it is written, and its show procedure and keymap when it runs"
  (check-equal? '("a show clause is required" "clause given twice" "invalid clause")
    (map (lambda (name)
           (guard (c [(syntax-violation? c) (condition-message c)])
             (load-module! (list 'status-line-test name))))
         '(no-show show-twice unknown-clause)))
  (check-raises (status-line-test:raised? 'status-line:define-segment "not a procedure") (load-module! '(status-line-test show-number)))
  (check-raises (status-line-test:raised? 'status-line:define-segment "not a keymap or #f") (load-module! '(status-line-test keymap-symbol))))

(test "the places check their numbers, and place? tells a place"
  (check-raises (status-line-test:raised? 'status-line:left "not a real number") (status-line:left 'far))
  (check-raises (status-line-test:raised? 'status-line:right "not a real number") (status-line:right "1"))
  (check-equal? '(#t #t #f) (map status-line:place? (list (status-line:left 1) (status-line:right 2.5) 'left))))

(test "draw raises for what is not a view and on another thread"
  (check-raises (status-line-test:raised? 'status-line:draw "not a view") (status-line:draw 'v (test-user:client)))
  (let ([v (view)] [result #f])
    (join-task (fork-task (lambda (restore) (set! result (guard (c [(assertion-violation? c) (condition-message c)]) (status-line:draw v #f))))))
    (check-equal? "not on the main thread" result)))

(define (percent-at p) (views:set-point! (view) p) (status-line:show-percent-position (view)))

(test "the percent position is Top at the start, Bot at the end, All when empty, else the characters before point as a rounded-up percentage, at most 99"
  (show! "abc\ndef\nghij\n")
  (check-equal? '("Top" "8%" "93%" "Bot") (map percent-at '(1 2 13 14)))
  (check-equal? "Bot" (text status-line:percent-position))
  (show! (make-string 200 #\x))
  (check-equal? '("1%" "99%" "Bot") (map percent-at '(2 200 201)))
  (show! "")
  (check-equal? "All" (status-line:show-percent-position (view))))

(test "a narrowed view's percent position counts only what it shows"
  (show! "abc\ndef\nghij\n")
  (views:narrow! (view) 5 9)
  (check-equal? '("Top" "50%" "Bot") (map percent-at '(5 7 9)))
  (views:widen! (view)))

(define (region-at mark p) (views:set-point! (view) p) (views:set-mark! (view) mark) (status-line:show-region-size (view)))

(define (regions . marks-and-points)
  (for-each (lambda (c) (views:remove-cursor! (view) c)) (cdr (views:cursors (view))))
  (views:set-point! (view) (cadr marks-and-points))
  (views:set-mark! (view) (car marks-and-points))
  (let loop ([rest (cddr marks-and-points)])
    (unless (null? rest)
      (views:set-cursor! (views:add-cursor! (view) (cadr rest)) (cadr rest) (car rest))
      (loop (cddr rest))))
  (status-line:show-region-size (view)))

(test "the region size shows while a cursor has a region: its characters, its lines when more than one, and the cursors when several"
  (show! "abc\ndef\nghij\n")
  (check-equal? #f (status-line:show-region-size (view)))
  (check-equal? '("2 characters" "2 characters" "8 characters, 2 lines" "9 characters, 3 lines" #f "1 character")
    (list (region-at 1 3) (region-at 3 1) (region-at 1 9) (region-at 1 10) (region-at 3 3) (region-at 1 2)))
  (check-equal? "1 character" (text status-line:region-size))
  (region-at 1 3)
  (views:set-cursor! (views:add-cursor! (view) 6) 6 5)
  (views:add-cursor! (view) 14)
  (check-equal? "3 characters, 2 lines, 3 cursors" (status-line:show-region-size (view)))
  (views:set-mark! (view) #f)
  (check-equal? "1 character, 3 cursors" (status-line:show-region-size (view)))
  (for-each (lambda (c) (views:set-cursor! c (views:cursor-point c) #f)) (views:cursors (view)))
  (check-equal? "" (text status-line:region-size)))

(test "regions that overlap or share a line count each character and each line once"
  (show! "abc def\nxyz\nend\n")
  (check-equal? '("3 characters, 2 cursors" "6 characters, 2 cursors" "10 characters, 2 lines, 2 cursors"
                  "9 characters, 3 lines, 2 cursors" "12 characters, 2 lines, 2 cursors" #f)
    (list (regions 4 1 4 2) (regions 1 4 5 8) (regions 1 10 9 11) (regions 5 10 10 14) (regions 1 9 9 13) (regions 1 1))))

(test "the size is that of the ranges views:region-ranges gives, so a region advised to be two short ranges counts them alone"
  (show! "abc def\nxyz\nend\n")
  (let ([two-ranges (lambda (region-ranges view cursor) (list (cons 1 3) (cons 9 11)))])
    (advice-add! views:region-ranges two-ranges)
    (check-equal? "4 characters, 2 lines" (regions 1 13))
    (advice-remove! views:region-ranges two-ranges)))

(test "show-region-size and show-percent-position check their view"
  (check-raises (status-line-test:raised? 'status-line:show-region-size "not a view") (status-line:show-region-size 5))
  (check-raises (status-line-test:raised? 'status-line:show-percent-position "not a view") (status-line:show-percent-position 5)))

(test "a region counts the text atoms stand for, and the percent position counts each atom as one character"
  (views:set-buffer! (view) (buffers:make "rows" (cards:rows '() (cards:row '((label . "one"))) (cards:row '((label . "two"))) (cards:blank '()))))
  (check-equal? '("8 characters, 2 lines" "4 characters" "4 characters" "8 characters, 2 lines")
    (list (regions 1 3) (regions 1 2) (regions 2 4) (regions 1 4)))
  (check-equal? '("Top" "34%" "67%") (map percent-at '(1 2 3))))

(test "the position is what views:position-description gives in the view: the kind at point describes it, else the line, and #f shows nothing"
  (let ([rows (views:buffer (view))] [describe (lambda (node view) (format "row at ~a" (document:node-start node)))])
    (views:set-point! (view) 1)
    (for-each (lambda (c) (views:remove-cursor! (view) c)) (cdr (views:cursors (view))))
    (views:set-mark! (view) #f)
    (check-equal? "L1" (text status-line:position))
    (tables:set! views:position-describers cards:row describe)
    (views:set-point! (view) 2)
    (check-equal? "row at 2" (text status-line:position))
    (buffers:with-buffer rows (options:set-local! views:position-description #f))
    (check-equal? (list #f "") (list (views:with-view (view) (status-line:show-position (view))) (text status-line:position)))
    (tables:remove! views:position-describers cards:row)))

(test "the docs' example of the percent position holds"
  (views:set-buffer! (view) (buffers:make (buffers:free-name "notes") "abc\ndef\nghij\n"))
  (views:set-point! (view) 13)
  (check-equal? "93%" (status-line:show-percent-position (view))))
