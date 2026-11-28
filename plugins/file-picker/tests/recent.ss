(import (tuna) (test) (test-runner) (test-user) (timers) (options) (keys) (tables) (commands) (buffers) (document) (views)
        (layout) (files) (completion) (completion-list) (buffer-picker) (file-picker) (save-place)
        (completion-test sessions) (completion-test picking))

(define (home name) (string-append (getenv "HOME") "/" name))

(define (write! name text) (call-with-output-file (home name) (lambda (p) (put-string p text)) 'replace))

(define (view) (layout:selected-view))

(define (shown-path) (let ([b (views:buffer (view))]) (and b (files:path b))))

(define (question)
  (let ([shown (test-user:elements (test-user:screen) "minibuffer-question")])
    (and (pair? shown) (test-user:element-text (car shown)))))

(for-each (lambda (name) (write! name (string-append name "\none\ntwo\nthree\n"))) '("a.txt" "b.txt" "c.txt"))

(define scratch (buffers:make "scratch" "scratch\n"))

;; Visited, then killed, so they are recorded and no buffer holds them; a.txt
;; is left at its third line, which save-place keeps.
(let ([a (files:visit (home "a.txt"))])
  (layout:switch-to-buffer a)
  (views:set-point! (view) 12)
  (layout:switch-to-buffer scratch)
  (buffers:kill! a))
(buffers:kill! (files:visit (home "b.txt")))

(test "find-recent-file has no key, as Emacs binds none to recentf-open; M-x offers it as a command"
  (check-equal? #f (exists (lambda (entry) (eq? (cdr entry) file-picker:find-recent-file)) (tables:entries keys:global)))
  (check (commands:command? file-picker:find-recent-file)))

(keys:bind! keys:global "C-c r" file-picker:find-recent-file)

(test "it reads from the recent files, newest first, as files:abbreviated-path writes them, in the file category, with the prompt Find recent file"
  (test-user:press! "C-c r")
  (check-equal? '("~/b.txt" "~/a.txt") (completion-test/picking:choices))
  (check-equal? "Find recent file: " (question))
  (check-equal? (list completion:file-category) (completion:session-categories (completion-test/picking:session)))
  (check-equal? '(cancelled) (completion-test/picking:quit!)))

(test "a match is required: RET on an input that names no recent file ends nothing"
  (test-user:press! "C-c r")
  (test-user:type! "zzz")
  (check-equal? '() (completion-test/picking:choices))
  (test-user:press! "RET")
  (check (completion-test/picking:session))
  (check-equal? '(cancelled) (completion-test/picking:quit!)))

(test "RET visits the file chosen and shows it in the selected view, at its saved place"
  (test-user:press! "C-c r")
  (test-user:type! "~/a")
  (check-equal? '("~/a.txt") (completion-test/picking:choices))
  (completion-test/picking:press-until-ended! "RET" file-picker:find-recent-file)
  (check-equal? (list (home "a.txt") 12) (list (shown-path) (views:point (view))))
  (layout:switch-to-buffer scratch)
  (buffers:kill! (files:buffer-visiting (home "a.txt"))))

(test "a recent file that no longer exists is not listed, and the list keeps it until a cleanup"
  (files:visit (home "c.txt"))
  (delete-file (home "c.txt"))
  (test-user:press! "C-c r")
  (check-equal? '("~/a.txt" "~/b.txt") (completion-test/picking:choices))
  (check (member (home "c.txt") (files:recent-files)))
  (check-equal? '(cancelled) (completion-test/picking:quit!)))

(test "file-picker:preview-delay is 0 by default; set, the selection shows the file in the selected view once it has rested that long, as a temporary visit, and a quit puts back what was shown"
  (check-equal? 0 (file-picker:preview-delay))
  (options:set! file-picker:preview-delay 0.4)
  (let ([started (real-time)] [v (view)])
    (define (shown) (let ([b (views:buffer v)]) (and b (files:path b))))
    (test-user:press! "C-c r")
    (completion-test/picking:choices)
    (test-runner:wait-until (lambda () (equal? (home "a.txt") (shown))))
    (check (>= (- (real-time) started) 400))
    (check (files:temporary? (views:buffer v)))
    (check-equal? '(cancelled) (completion-test/picking:quit!))
    (check-equal? scratch (views:buffer v)))
  (check-equal? #f (files:buffer-visiting (home "a.txt")))
  (options:unset! file-picker:preview-delay))

(define (remove-duplicates titles)
  (fold-right (lambda (t kept) (if (member t kept) kept (cons t kept))) '() titles))

(define (with-recent-in-switch thunk)
  (options:set! buffer-picker:sources (list buffer-picker:buffers file-picker:recent-files))
  (thunk)
  (options:unset! buffer-picker:sources))

(test "with file-picker:recent-files in buffer-picker:sources, C-x b lists a group Recent files, narrowed by f, after the buffers, of locations; a file open in a buffer is left out"
  (with-recent-in-switch
    (lambda ()
      (let ([b (files:visit (home "b.txt"))])
        (test-user:press! "C-x b")
        (let ([s (completion-test/picking:session)])
          (let ([groups (map (lambda (m text) (cons (completion:title s m) text))
                             (completion-test/sessions:matches s) (completion-test/picking:choices))])
            (check (member (cons "Buffers" "b.txt") groups))
            (check-equal? '(("Recent files" . "~/a.txt")) (filter (lambda (g) (equal? (car g) "Recent files")) groups))
            (check-equal? "Recent files" (car (list-ref groups (- (length groups) 1)))))
          (check-equal? (list completion:buffer-category completion:location-category) (completion:session-categories s))
          (test-user:type! "f ")
          (check-equal? "Recent files" (completion:narrowed (completion-test/picking:session))))
        (check-equal? '(cancelled) (completion-test/picking:quit!))
        (buffers:kill! b)))))

(test "choosing a recent file there visits it and shows it at its place"
  (with-recent-in-switch
    (lambda ()
      (test-user:press! "C-x b")
      (test-user:type! "a.t")
      (completion-test/picking:choices)
      (completion-test/picking:press-until-ended! "RET" buffer-picker:switch-to-buffer)
      (check-equal? (list (home "a.txt") 12) (list (shown-path) (views:point (view))))
      (layout:switch-to-buffer scratch)
      (buffers:kill! (files:buffer-visiting (home "a.txt"))))))

(test "with the recent list empty, C-x b shows no Recent files group"
  (for-each files:forget-recent! (files:recent-files))
  (with-recent-in-switch
    (lambda ()
      (test-user:press! "C-x b")
      (let ([s (completion-test/picking:session)])
        (completion-test/picking:choices)
        (check-equal? '("Buffers") (remove-duplicates (map (lambda (m) (completion:title s m)) (completion-test/sessions:matches s)))))
      (check-equal? '(cancelled) (completion-test/picking:quit!)))))
