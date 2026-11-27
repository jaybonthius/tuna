(import (tuna) (test) (test-runner) (test-user) (tables) (options) (buffers) (views) (web) (layout) (layout-split) (modes)
        (treesit) (python) (views-test page) (treesit-test) (treesit-test grammar) (treesit-test session))

(define python (tables:ref treesit:grammars "python" #f))
(treesit-test/grammar:build-python! (treesit:grammar-commit python) (treesit:grammar-file python))

(options:set! views:scroll-margin 2 views:wrap-lines #f)

;; Each page here reports its own scrolls; test-user's own page reports
;; none, so its drawn range would stay where the view was first placed.
(web:close-client! (test-user:client))

(define desktop (views-test/page:open 400))

(define v (layout:selected-view))

(define text (treesit-test:grown-text 60000))

(define (fresh-runs b)
  (treesit-test/session:runs
    (treesit-test/session:highlighted (treesit:grammar-file python) (treesit-test:text-of b) (treesit-test/session:shipped)
      (options:default treesit:excluded-captures))))

(define (drawn-lines view b) (map (lambda (r) (treesit-test:lines-of b r)) (views:drawn-ranges view)))

(define (drawn-runs b) (map (lambda (r) (treesit-test:runs b (car r) (cdr r))) (views:drawn-ranges v)))

(define first-runs #f)
(define watched #f)

(advice-add! buffers:set-spans!
  (lambda (set layer start end spans . version)
    (let ([result (apply set layer start end spans version)])
      (when (and watched (not first-runs) (buffers:live? watched) (pair? (views:drawn-ranges v)))
        (set! first-runs (drawn-runs watched)))
      result)))

(define (watch! b)
  (set! watched b)
  (set! first-runs #f)
  (treesit-test:sets b))

(define (fresh-in-drawn b)
  (let ([fresh (treesit-test:buffer "fresh.py" (treesit-test:text-of b) python:mode)])
    (treesit-test:runs-become fresh (fresh-runs b))
    (let ([runs (map (lambda (r) (treesit-test:runs fresh (car r) (cdr r))) (views:drawn-ranges v))])
      (buffers:kill! fresh)
      runs)))

(define b (buffers:make "big.py" text))

(test "a view placed at line 1000 is drawn with a margin beyond each edge, and the job's first answer holds that range in its final colours"
  (watch! b)
  (views:set-buffer! v b)
  (views:scroll-to! v (treesit-test:line-start b 1000) (views:align top))
  (test-user:settle)
  (check-equal? '((900 1100)) (drawn-lines v b))
  (modes:set-major-mode python:mode b)
  (test-runner:wait-until (lambda () first-runs))
  (check-equal? '(900 1099) (treesit-test:lines-of b (apply cons (car (treesit-test:sets b)))))
  (treesit-test:runs-become b (fresh-runs b))
  (check-equal? (drawn-runs b) first-runs)
  (check-equal? 548 (length (car first-runs))))

(test "once the buffer is coloured, a scroll that moves the drawn range colours nothing again"
  (treesit-test:sets b)
  (views-test/page:report! desktop v 1300 0 #t)
  (check-equal? '((1259 1341)) (drawn-lines v b))
  (test-user:settle)
  (check-equal? '() (treesit-test:sets b)))

(test "right after an edit that changes the structure, the job's first answer colours the whole drawn range, its margins included"
  (watch! b)
  (buffers:insert! b (treesit-test:line-start b 1300) "\"\"\"")
  (test-runner:wait-until (lambda () first-runs))
  (check-equal? (fresh-in-drawn b) first-runs)
  (treesit-test:runs-become b (fresh-runs b))
  (views-test/page:report! desktop v 1290 0 #t)
  (views-test/page:report! desktop v 1310 0 #t)
  (test-user:settle)
  (check-equal? (fresh-runs b) (treesit-test:runs b)))

(define c (buffers:make "two.py" text))

(test "of two views of a buffer, each drawn range is coloured before anything else, and both show the same colours"
  (views:set-buffer! v c)
  (views:scroll-to! v (treesit-test:line-start c 1000) (views:align top))
  (let ([w (layout-split:split-view! v (layout-split:direction column) c)])
    (views:scroll-to! w (treesit-test:line-start c 300) (views:align top))
    (test-user:settle)
    (let ([ranges (append (views:drawn-ranges v) (views:drawn-ranges w))])
      (check-equal? '((900 1100) (200 400)) (map (lambda (r) (treesit-test:lines-of c r)) ranges))
      (treesit-test:sets c)
      (modes:set-major-mode python:mode c)
      (treesit-test:runs-become c (fresh-runs c))
      (check-equal? '(#t #t #f)
                    (map (lambda (s) (exists (lambda (r) (and (<= (car r) (car s)) (<= (cadr s) (cdr r)))) ranges))
                         (list-head (treesit-test:sets c) 3))))
    (check-equal? '(#t #t)
                  (map (lambda (view)
                         (exists (lambda (e) (equal? "function" (test-user:element-attribute e "data-face")))
                                 (test-user:elements-with (views-test/page:shown-element desktop view) "data-face")))
                       (list v w)))
    (layout:delete-part! (layout:view-node w))))

(test "back to a buffer in a view's history, its colours show at once: the buffer kept them, and its job goes on"
  (let ([other (treesit-test:buffer "other.py" "x = 1\n" python:mode)])
    (treesit-test:runs-become other '(("x" variable.definition) ("1" number)))
    (treesit-test:job-events)
    (views:set-buffer! v other)
    (test-user:settle)
    (check (eq? c (views:previous-buffer! v)))
    (test-user:settle)
    (check (exists (lambda (e) (equal? "function" (test-user:element-attribute e "data-face")))
                   (test-user:elements-with (views-test/page:shown-element desktop v) "data-face")))
    (check-equal? '() (treesit-test:job-events))))
