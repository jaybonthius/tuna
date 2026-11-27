(import (tuna) (test) (test-user) (test-runner) (hooks) (buffers) (views) (layout) (editing) (minibuffer) (completion)
        (completion-list) (files) (file-picker) (buffer-picker) (line-picker) (grep) (dired) (jump-history) (jump-history-test))

(define here jump-history-test:here)

(define places jump-history-test:places)

(define line! jump-history-test:line!)

(define (home-path name) (string-append (getenv "HOME") "/" name))

(define (write-file! name text) (call-with-output-file (home-path name) (lambda (p) (put-string p text)) 'replace))

(for-each mkdir (map home-path '("notes" "notes/.git")))
(write-file! "notes/a.txt" "one\ntwo\nthree\nfour\nfive\n")
(write-file! "notes/defs.txt" "def total\n")
(write-file! "notes/uses.txt" "x = total\n")

(files:visit (home-path "notes/defs.txt"))

(layout:switch-to-buffer (files:visit (home-path "notes/a.txt")))

;; Visiting a file and listing a folder pause past test-user:settle.
(define (press-until-shown! keys name)
  (test-user:press! keys)
  (test-runner:wait-until (lambda () (equal? name (buffers:name (views:buffer (jump-history-test:view)))))))

(define (choose! keys typed)
  (test-user:press! keys)
  (test-user:type! typed)
  (jump-history-test:choices))

(test "M-< and M-> record the place they leave; a second M-< at the start records nothing"
  (line! 3)
  (test-user:press! "M-<")
  (check-equal? '(("a.txt" 1) (("a.txt" 3))) (list (here) (places)))
  (test-user:press! "M-<")
  (check-equal? '(("a.txt" 3)) (places))
  (test-user:press! "M-,")
  (check-equal? '("a.txt" 3) (here))
  (test-user:press! "C-M-,")
  (check-equal? '("a.txt" 1) (here))
  (test-user:press! "M->")
  (check-equal? '(("a.txt" 6) ("a.txt" 1)) (list (here) (car (places)))))

(test "M-g g records the place it leaves and runs jump-history:after-jump"
  (line! 3)
  (let* ([jumped 0] [note (lambda (v) (set! jumped (+ jumped 1)))])
    (hooks:add! jump-history:after-jump note)
    (test-user:press! "M-g g")
    (test-user:type! "5")
    (test-user:press! "RET")
    (hooks:remove! jump-history:after-jump note)
    (check-equal? '(("a.txt" 5) 1) (list (here) jumped)))
  (test-user:press! "M-,")
  (check-equal? '("a.txt" 3) (here))
  (test-user:press! "C-M-,")
  (check-equal? '("a.txt" 5) (here)))

(test "M-s l and M-s r record the place they leave"
  (line! 3)
  (choose! "M-s l" "four")
  (test-user:press! "RET")
  (check-equal? '("a.txt" 4) (here))
  (test-user:press! "M-,")
  (check-equal? '("a.txt" 3) (here))
  (check-equal? '(("a.txt" "a.txt:5:five")) (choose! "M-s r" "five"))
  (test-user:press! "RET")
  (test-runner:wait-until (lambda () (equal? '("a.txt" 5) (here))))
  (test-user:press! "M-,")
  (check-equal? '("a.txt" 3) (here)))

(test "C-x b records the place it leaves, and its preview records nothing"
  (let ([before (places)])
    (test-user:press! "C-x b")
    (test-user:press! "C-n")
    (check-equal? '(cancelled) (jump-history-test:press-reporting! "C-g"))
    (check-equal? before (places)))
  (test-user:press! "C-x b")
  (test-user:type! "defs.txt")
  (test-user:press! "RET")
  (check-equal? '("defs.txt" 1) (here))
  (test-user:press! "M-,")
  (check-equal? '("a.txt" 3) (here))
  (test-user:press! "C-M-,")
  (check-equal? '("defs.txt" 1) (here))
  (test-user:press! "M-,"))

(test "C-x C-f records the place it leaves"
  (test-user:press! "C-x C-f C-a C-k")
  (test-user:type! (home-path "notes/uses.txt"))
  (press-until-shown! "RET" "uses.txt")
  (test-user:press! "M-,")
  (check-equal? '("a.txt" 3) (here)))

(test "C-x d, a listing's RET and ^ record the place they leave"
  (test-user:press! "C-x d")
  (press-until-shown! "RET" "~/notes/")
  (test-user:press! "M-,")
  (check-equal? '("a.txt" 3) (here))
  (test-user:press! "C-M-,")
  (check-equal? "~/notes/" (car (here)))
  (test-user:press! "n")
  (press-until-shown! "RET" "a.txt")
  (check-equal? '("a.txt" 3) (here))
  (test-user:press! "M-,")
  (check-equal? "~/notes/" (car (here)))
  (press-until-shown! "^" "~/")
  (test-user:press! "M-,")
  (check-equal? "~/notes/" (car (here))))

(test "dired's o shows a file in another view and selects it, which is no jump and records nothing"
  (let ([before (places)] [listing (views:buffer (jump-history-test:view))])
    (press-until-shown! "o" "a.txt")
    (check (layout:find-view listing))
    (check (not (eq? (layout:find-view listing) (jump-history-test:view))))
    (check-equal? before (places))))

(test "M-s r to a file another view shows goes to that view and selects it"
  (let ([shown-a (jump-history-test:view)])
    (test-user:press! "C-x o")
    (layout:switch-to-buffer (buffers:find "defs.txt"))
    (choose! "M-s r" "five")
    (test-user:press! "RET")
    (check-equal? (list #t '("a.txt" 5)) (list (eq? (jump-history-test:view) shown-a) (here)))))
