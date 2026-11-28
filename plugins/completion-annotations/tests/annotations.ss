(import (tuna) (test) (test-user) (commands) (keys) (buffers) (files) (faces) (completion) (completion-list)
        (completion-annotations) (completion-test sessions) (minibuffer-test reading) (completion-annotations-test gestures))

(define (quit! r)
  (test-user:press! "C-g")
  (check-raises cancelled? (minibuffer-test/reading:result r)))

(define (read-of category candidates)
  (minibuffer-test/reading:start!
    (lambda () (completion:read "? " (list (completion:source (candidates candidates) (category category) (in-order))) #f))))

(define (annotations)
  (let ([s (completion-test/sessions:session)])
    (completion-test/sessions:wait-matches s)
    (map (lambda (m) (cons (completion:text s m) (completion:annotation s m))) (completion-test/sessions:matches s))))

(define (drawn-annotations)
  (map (lambda (e) (list (test-user:element-text e) (test-user:element-attribute e "data-face")))
       (test-user:elements (test-user:screen) "completion-column")))

(test "a command is annotated with its first key for the session's client, in the keyword face, and its documentation's first line in the shadow face"
  (let ([r (read-of completion:command-category (vector (cons "wave" completion-annotations-test/gestures:wave)
                                                        (cons "nod" completion-annotations-test/gestures:nod)))])
    (check-equal? (list (list "wave" (cons faces:keyword "C-c w") (cons faces:shadow "Waves a hand."))
                        (list "nod" (cons faces:keyword "") (cons faces:shadow "Nods.")))
                  (annotations))
    (check-equal? (list (list "C-c w" (symbol->string faces:keyword)) (list "Waves a hand." (symbol->string faces:shadow)))
                  (list-head (drawn-annotations) 2))
    (quit! r)))

(test "a command's keys are looked up once a session, and only for the rows drawn"
  (let* ([asked '()]
         [count (lambda (next client command) (set! asked (cons command asked)) (next client command))]
         [all (map commands:command-named (commands:public-command-names))])
    (advice-add! keys:where-is count)
    (let ([r (read-of completion:command-category
                      (list->vector (map (lambda (c) (cons (symbol->string (commands:command-name c)) c)) all)))])
      (completion-test/sessions:wait-matches (completion-test/sessions:session))
      (test-user:press! "C-n C-n C-p")
      (check (< 0 (length asked) (length all)))
      (check (for-all (lambda (c) (= 1 (length (filter (lambda (a) (eq? a c)) asked)))) asked))
      (quit! r))
    (advice-remove! keys:where-is count)))

(test "a buffer is annotated with its length in characters and the file it visits, as ~ writes the home folder, in the shadow face"
  (let* ([path (string-append (getenv "HOME") "/visited.txt")]
         [visited (begin (call-with-output-file path (lambda (p) (put-string p "four\n"))) (files:visit path))]
         [plain (buffers:make "plain" "twelve chars")]
         [r (read-of completion:buffer-category (vector (cons "visited.txt" visited) (cons "plain" plain)))])
    (check-equal? (list (list "visited.txt" (cons faces:shadow "5") (cons faces:shadow "~/visited.txt"))
                        (list "plain" (cons faces:shadow "12") (cons faces:shadow "")))
                  (annotations))
    (quit! r)
    (buffers:kill! plain)
    (buffers:kill! visited)))

(test "a file's size is written as ls -lh writes it and its time as an age for two weeks, then a date; without details it has no columns"
  (let* ([annotate (completion-annotations:file #f)]
         [now (time-second (current-time 'time-utc))]
         [old (time-second (date->time-utc (make-date 0 0 0 12 15 1 2020 (date-zone-offset (current-date)))))])
    (check-equal? '(("512" "2h 10m ago") ("1.5k" "1m 30s ago") ("10k" "3d ago") ("2.9M" "5s ago") ("0" "2020 Jan 15"))
      (map (lambda (details) (map cdr (annotate "f" details)))
           (list (cons 512 (- now 7800)) (cons 1536 (- now 90)) (cons 10500 (- now (* 3 86400))) (cons 3000000 (- now 5))
                 (cons 0 old))))
    (check (for-all (lambda (column) (eq? faces:shadow (car column))) (annotate "f" (cons 512 now))))
    (check-equal? '() (annotate "f" #f))))

(test "a name or an identifier whose details are a symbol is annotated with that kind in the shadow face, any other with nothing"
  (for-each
    (lambda (category)
      (let ([r (read-of category (vector (vector "car" 'car 'procedure) (vector "x" 'x "not a kind") "y"))])
        (check-equal? (list (list "car" (cons faces:shadow "procedure")) (list "x") (list "y")) (annotations))
        (quit! r)))
    (list completion:name-category completion:identifier-category)))
