(import (tuna) (test) (test-runner) (test-user) (modes) (buffers) (files) (auto-mode) (hooks) (options) (tables)
        (syntax-highlighting) (syntax-highlighting-test) (syntax-highlighting-test marks))

(define marked syntax-highlighting-test:marked)
(define (faces b) (syntax-highlighting-test/marks:faces b))
(define (faces-become b expected) (syntax-highlighting-test/marks:faces-become b expected))
(define (parens-become b expected) (syntax-highlighting-test/marks:parens-become b expected))
(define job-events syntax-highlighting-test:job-events)

(define (home-file name) (string-append (getenv "HOME") "/" name))

(define (write-file! name text)
  (call-with-output-file (home-file name) (lambda (p) (put-string p text)) 'replace))

(tables:set! auto-mode:file-names "mk" syntax-highlighting-test/marks:mode)

(test "syntax-highlighting:mode is a minor mode, on by default, with no keymap and no lighter, named as modes names minor modes"
  (check-equal? '(#t 0 #f #f syntax-highlighting:mode)
                (list (syntax-highlighting:mode) (tables:ref modes:minor-modes syntax-highlighting:mode #f)
                      (tables:ref modes:keymaps syntax-highlighting:mode #f) (modes:lighter syntax-highlighting:mode)
                      (modes:name syntax-highlighting:mode))))

(define f (marked "f.mk" "#a (b)\n" syntax-highlighting-test/marks:mode))

(test "turned off in a buffer, its faces go at the end of the batch and its other layers stay; the job goes on and edits reach it"
  (faces-become f '(("#a" comment)))
  (parens-become f '("(" ")"))
  (check-equal? '((start %marks)) (job-events))
  (syntax-highlighting-test/marks:inputs)
  (buffers:with-buffer f (options:set-local! syntax-highlighting:mode #f))
  (check-equal? 1 (length (syntax-highlighting-test:spans-of f syntax-highlighting:faces)))
  (faces-become f '())
  (check-equal? '("(" ")") (syntax-highlighting-test/marks:paren-texts f))
  (buffers:insert! f 1 "#n (c) ")
  (parens-become f '("(" ")" "(" ")"))
  (check-equal? '() (faces f))
  (syntax-highlighting-test/marks:inputs-become '(("f.mk" (2 ((0 0 7))) 0))))

(test "on again, every face comes back from the job's record, without the job highlighting again"
  (syntax-highlighting-test/marks:inputs)
  (buffers:with-buffer f (options:set-local! syntax-highlighting:mode #t))
  (faces-become f '(("#n" comment) ("#a" comment)))
  (test-user:settle)
  (check-equal? '(() ()) (list (syntax-highlighting-test/marks:inputs) (job-events))))

(test "the global value turns faces off in every buffer without a local one"
  (let ([g (marked "g.mk" "#g" syntax-highlighting-test/marks:mode)])
    (faces-become g '(("#g" comment)))
    (options:set! syntax-highlighting:mode #f)
    (faces-become g '())
    (check-equal? '(("#n" comment) ("#a" comment)) (faces f))
    (options:set! syntax-highlighting:mode #t)
    (faces-become g '(("#g" comment)))
    (buffers:kill! g)))

(test "a mode hook that turns it off starts the buffer's job without faces"
  (let ([plain! (lambda () (options:set-local! syntax-highlighting:mode #f))])
    (hooks:add! syntax-highlighting-test/marks:mode-hook plain!)
    (let ([h (marked "h.mk" "#h (i)" syntax-highlighting-test/marks:mode)])
      (parens-become h '("(" ")"))
      (check-equal? '() (faces h))
      (buffers:with-buffer h (options:set-local! syntax-highlighting:mode #t))
      (faces-become h '(("#h" comment)))
      (buffers:kill! h))
    (hooks:remove! syntax-highlighting-test/marks:mode-hook plain!)))

(define p #f)

(test "a preview's file is coloured; visiting it in full runs the hooks, which set no mode, so the job goes on"
  (job-events)
  (write-file! "notes.mk" "#note (x)\n")
  (set! p (files:visit-temporarily (home-file "notes.mk")))
  (check-equal? (list syntax-highlighting-test/marks:mode #t) (list (modes:major-mode p) (modes:hooks-delayed? p)))
  (faces-become p '(("#note" comment)))
  (check-equal? '((start %marks)) (job-events))
  (check (eq? p (files:visit (home-file "notes.mk"))))
  (check-equal? #f (modes:hooks-delayed? p))
  (test-user:settle)
  (check-equal? '() (job-events)))

(test "setting another mode right after a preview restarts the job, whose input runs again in the new scope"
  (syntax-highlighting-test/marks:inputs)
  (write-file! "other.mk" "#other\n")
  (let ([q (files:visit-temporarily (home-file "other.mk"))])
    (faces-become q '(("#other" comment)))
    (check-equal? '((start %marks)) (job-events))
    (test-runner:wait-until (lambda () (= 2 (syntax-highlighting-test/marks:inputs-count))))
    (check-equal? '("other.mk" "other.mk") (map car (syntax-highlighting-test/marks:inputs)))
    (modes:set-major-mode syntax-highlighting-test/marks:derived q)
    (test-runner:wait-until (lambda () (= 2 (syntax-highlighting-test/marks:inputs-count))))
    (faces-become q '(("#other" comment)))
    (check-equal? '((stop %marks) (start %marks)) (job-events))
    (check-equal? '("other.mk" "other.mk") (map car (syntax-highlighting-test/marks:inputs)))
    (buffers:kill! q)
    (test-user:settle)
    (check-equal? '((stop %marks)) (job-events))))

(define m (marked "m" "#m (y)" syntax-highlighting-test/marks:mode))

(test "unloading a language's plugin stops its jobs and their spans go; loading it again highlights its buffers again"
  (faces-become m '(("#m" comment)))
  (buffers:kill! f)
  (test-user:settle)
  (job-events)
  (unload-owner! (module-owner '(syntax-highlighting-test marks)))
  (test-user:settle)
  (check-equal? '((() ()) (() ())) (map syntax-highlighting-test:all-spans (list p m)))
  (check-equal? '((stop %marks) (stop %marks)) (job-events))
  (load-module! '(syntax-highlighting-test marks))
  (faces-become p '(("#note" comment)))
  (faces-become m '(("#m" comment)))
  (parens-become m '("(" ")"))
  (check-equal? '((start %marks) (start %marks)) (job-events)))

(test "unloading syntax-highlighting stops every job and takes its spans away, and the plugins that import it go with it"
  (unload-owner! (module-owner '(syntax-highlighting)))
  (test-user:settle)
  (check-equal? '((() ()) (() ())) (map syntax-highlighting-test:all-spans (list p m)))
  (check-equal? '(#f #f) (map (lambda (name) (and (member name (loaded-modules)) #t)) '((syntax-highlighting) (syntax-highlighting-test marks))))
  (load-module! '(syntax-highlighting-test marks))
  (faces-become p '(("#note" comment)))
  (faces-become m '(("#m" comment))))
