(import (tuna) (test) (test-runner) (test-user) (tables) (options) (buffers) (document) (views) (layout) (modes)
        (treesit) (python) (treesit-test) (treesit-test grammar) (treesit-test session))

(define python (tables:ref treesit:grammars "python" #f))
(treesit-test/grammar:build-python! (treesit:grammar-commit python) (treesit:grammar-file python))

(options:set! views:scroll-margin 2 views:wrap-lines #f)

(define v (layout:selected-view))

(define start-runs '(("#!/usr/bin/env python3" comment) ("\"\"\"A sample of Python for Tuna's highlighting tests.\"\"\"" string.documentation)))

(define watched #f)
(define first-drawn #f)
(define first-start #f)

(advice-add! buffers:set-spans!
  (lambda (set layer start end spans . version)
    (let ([result (apply set layer start end spans version)])
      (when (and watched (not first-drawn) (buffers:live? watched))
        (set! first-drawn (map (lambda (r) (treesit-test:runs watched (car r) (cdr r))) (views:drawn-ranges v)))
        (set! first-start (treesit-test:runs watched 0 (treesit-test:line-start watched 3))))
      result)))

(define (open! name text)
  (let ([b (buffers:make name text)])
    (treesit-test:sets b)
    (set! watched b)
    (set! first-drawn #f)
    (views:set-buffer! v b)
    b))

(test "a 1 MB file opened at line 20,000: what views has drawn is coloured first, in its final colours, and the rest follows in pieces"
  (let ([b (open! "large.py" (treesit-test:grown-text 1000000))])
    (views:scroll-to! v (treesit-test:line-start b 20000) (views:align top))
    (test-user:settle)
    (check-equal? '((19900 20100)) (map (lambda (r) (treesit-test:lines-of b r)) (views:drawn-ranges v)))
    (modes:set-major-mode python:mode b)
    (test-runner:wait-until (lambda () first-drawn))
    (check-equal? '(19900 20098) (treesit-test:lines-of b (apply cons (car (treesit-test:sets b)))))
    (check-equal? '() first-start)
    (treesit-test:runs-become
      b
      (treesit-test/session:runs
        (treesit-test/session:highlighted (treesit:grammar-file python) (treesit-test:text-of b) (treesit-test/session:shipped)
          (options:default treesit:excluded-captures))))
    (check-equal? (map (lambda (r) (treesit-test:runs b (car r) (cdr r))) (views:drawn-ranges v)) first-drawn)
    (check-equal? start-runs (treesit-test:runs b 0 (treesit-test:line-start b 3)))
    (check (> (length (treesit-test:sets b)) 20))
    (buffers:kill! b)))

(test "no size limit: a file of 42 MB, over Emacs's 40 MB, is parsed, and what views has drawn is coloured first"
  (let ([b (open! "huge.py" (treesit-test:grown-text 42000000))])
    (let ([doc (buffers:document b)])
      (check-equal? 42000266 (document:offset doc (document:length doc) (document:unit bytes))))
    (test-user:settle)
    (check-equal? '((1 101)) (map (lambda (r) (treesit-test:lines-of b r)) (views:drawn-ranges v)))
    (modes:set-major-mode python:mode b)
    (test-runner:wait-until (lambda () first-drawn))
    (check-equal? '(1 101) (treesit-test:lines-of b (apply cons (car (treesit-test:sets b)))))
    (check-equal? start-runs first-start)
    (buffers:kill! b)))
