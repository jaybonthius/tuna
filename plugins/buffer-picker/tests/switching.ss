(import (tuna) (test) (test-user) (options) (keys) (jobs) (buffers) (views) (layout) (layout-split)
        (files) (completion) (completion-list) (buffer-picker) (completion-test sessions) (completion-test picking))

(define (check-eq? a b) (check (eq? a b)))

(define (view) (layout:selected-view))

(define (shown-name) (buffers:name (views:buffer (view))))

(define (user-buffers) (remp (lambda (b) (buffers:internal-name? (buffers:name b))) (buffers:all)))

;; A quit says Quit, which makes *Messages*, a buffer no test here uses.
(define (order) (remp (lambda (name) (string=? name "*Messages*")) (map buffers:name (user-buffers))))

(define (only! . names)
  (for-each buffers:kill! (user-buffers))
  (map (lambda (name) (buffers:make name (string-append name "\n"))) names))

(define (home-file name text)
  (let ([path (string-append (getenv "HOME") "/" name)])
    (when (file-exists? path) (delete-file path))
    (call-with-output-file path (lambda (p) (put-string p text)))
    path))

(define (with-sources sources thunk)
  (options:set! buffer-picker:sources sources)
  (thunk)
  (options:unset! buffer-picker:sources))

(test "by default C-x b previews nothing: the selected view keeps its buffer until the choice"
  (let ([bs (only! "notes" "other")])
    (layout:switch-to-buffer (car bs))
    (let ([v (view)])
      (test-user:press! "C-x b")
      (test-user:type! "oth")
      (check-equal? '("other") (completion-test/picking:choices))
      (check-equal? "notes" (buffers:name (views:buffer v))))
    (test-user:press! "RET")
    (check-equal? "other" (shown-name))))

(test "with buffer-picker:buffers given the view, C-x b previews the selected buffer there, and a quit puts back the buffer, its point and its history"
  (with-sources (list buffer-picker:buffers)
    (lambda ()
      (let ([bs (only! "notes" "other")])
        (layout:switch-to-buffer (cadr bs))
        (layout:switch-to-buffer (car bs))
        (views:set-point! (view) 3)
        (let* ([v (view)] [history (views:previous-buffers v)])
          (test-user:press! "C-x b")
          (completion-test/picking:choices)
          (check-equal? (list "other" #t) (list (buffers:name (views:buffer v)) (views:previewing? v)))
          (check-equal? '(cancelled) (completion-test/picking:quit!))
          (check-equal? (list "notes" 3 #f) (list (shown-name) (views:point v) (views:previewing? v)))
          (check-equal? history (views:previous-buffers v)))))))

(test "a quit puts the view back before its preview ends, so the buffer previewed records no use"
  (with-sources (list buffer-picker:buffers)
    (lambda ()
      (only! "one" "two" "three")
      (layout:switch-to-buffer (buffers:find "three"))
      (let ([before (order)])
        (test-user:press! "C-x b")
        (completion-test/picking:choices)
        (check-equal? '(cancelled) (completion-test/picking:quit!))
        (check-equal? before (order))))))

(test "a view that shows no buffer still previews in C-x b and quits cleanly"
  (with-sources (list buffer-picker:buffers)
    (lambda ()
      (only!)
      (check-equal? #f (views:buffer (view)))
      (buffers:make "back" "b\n")
      (test-user:press! "C-x b")
      (completion-test/picking:choices)
      (check-equal? '(cancelled) (completion-test/picking:quit!))
      (buffers:kill! (buffers:find "*Messages*"))
      (test-user:press! "C-x b RET")
      (check-equal? "back" (shown-name)))))

(test "an input that names no buffer makes an empty buffer of that name"
  (only! "notes")
  (test-user:press! "C-x b")
  (test-user:type! "fresh")
  (completion-test/picking:choices)
  (test-user:press! "RET")
  (check-equal? (list "fresh" "|") (list (shown-name) (test-user:text))))

(test "C-x b lists the buffers used most recently first, those a view shows after them and the current one last, so RET returns to the one left last"
  (only! "one" "two" "three")
  (for-each (lambda (name) (layout:switch-to-buffer (buffers:find name))) '("one" "three" "two"))
  (test-user:press! "C-x b")
  (check-equal? '("three" "one" "two") (completion-test/picking:choices))
  (test-user:press! "RET")
  (check-equal? "three" (shown-name))
  (test-user:press! "C-x b RET")
  (check-equal? "two" (shown-name))
  (let ([right (layout-split:split-view! (view) (layout-split:direction row))])
    (views:set-buffer! right (buffers:find "three"))
    (test-user:press! "C-x b")
    (check-equal? '("one" "three" "two") (completion-test/picking:choices))
    (check-equal? '(cancelled) (completion-test/picking:quit!))
    (layout:delete-part! (layout:view-node right))))

(test "C-x k kills the buffer chosen, the current one by default"
  (only! "notes" "other")
  (layout:switch-to-buffer (buffers:find "notes"))
  (test-user:press! "C-x k")
  (check-equal? "notes" (completion-test/picking:selected))
  (test-user:press! "RET")
  (check-equal? '("other") (map buffers:name (user-buffers))))

(test "buffer-picker:read-buffer returns the buffer chosen, its default first"
  (let* ([bs (only! "notes" "other")]
         [r (completion-test/sessions:start! (lambda () (buffer-picker:read-buffer "Buffer: " buffer-picker:buffer-history (cadr bs))))])
    (check-equal? "other" (car (completion-test/picking:choices)))
    (test-user:press! "RET")
    (check-eq? (cadr bs) (completion-test/sessions:result r))))

(test "a location chosen in C-x b visits its file and goes to its line and column; a line past the last goes to the end"
  (let* ([path (home-file "lines.txt" "one\ntwo\nthree\n")]
         [lines (lambda (view)
                  (completion:source (candidates (vector (cons "lines.txt:2" (cons* path 2 1)) (cons "lines.txt:9" (cons* path 9 0))))
                                     (category completion:location-category)))])
    (with-sources (list buffer-picker:buffers lines)
      (lambda ()
        (only! "notes")
        (test-user:press! "C-x b")
        (test-user:type! "lines.txt:2")
        (completion-test/picking:choices)
        (completion-test/picking:press-until-ended! "RET" buffer-picker:switch-to-buffer)
        (check-equal? "one\nt|wo\nthree\n" (test-user:text))
        (test-user:press! "C-x b")
        (test-user:type! "lines.txt:9")
        (completion-test/picking:choices)
        (completion-test/picking:press-until-ended! "RET" buffer-picker:switch-to-buffer)
        (check-equal? "one\ntwo\nthree\n|" (test-user:text))))
    (check-raises (lambda (c) (and (who-condition? c) (eq? 'buffer-picker:switch-to-buffer (condition-who c))))
                  (buffer-picker:switch-to-buffer 5))))

(jobs:define-worker (notes-files directory emit)
  (emit (list->vector
          (map (lambda (name) (cons name (cons* (string-append directory "/" name) 1 0)))
               (directory-list directory)))))

(define (notes-source view)
  (completion:source
    (job notes-files (string-append (getenv "HOME") "/notes"))
    (category completion:location-category)
    (title "Notes")))

(test "a source added to buffer-picker:sources, as the page's notes, offers its candidates beside the buffers"
  (unless (file-exists? (string-append (getenv "HOME") "/notes")) (mkdir (string-append (getenv "HOME") "/notes")))
  (home-file "notes/a.txt" "alpha\n")
  (with-sources (list buffer-picker:buffers notes-source)
    (lambda ()
      (only! "notes")
      (test-user:press! "C-x b")
      (check-equal? '("notes" "a.txt") (completion-test/picking:choices))
      (test-user:type! "a.t")
      (let ([s (completion-test/picking:session)])
        (completion-test/picking:choices)
        (check-equal? '("Notes") (map (lambda (m) (completion:title s m)) (completion-test/sessions:matches s))))
      (completion-test/picking:press-until-ended! "RET" buffer-picker:switch-to-buffer)
      (check-equal? (string-append (getenv "HOME") "/notes/a.txt") (files:path (views:buffer (view)))))))

(test "the buffers narrow by b only in a read of more sources: alone, b SPC types a space"
  (only! "notes")
  (test-user:press! "C-x b")
  (test-user:type! "b ")
  (check-equal? (list "b " #f) (list (completion-test/sessions:input) (completion:narrowed (completion-test/picking:session))))
  (check-equal? '(cancelled) (completion-test/picking:quit!))
  (test-user:press! "C-x k")
  (test-user:type! "b ")
  (check-equal? (list "b " #f) (list (completion-test/sessions:input) (completion:narrowed (completion-test/picking:session))))
  (check-equal? '(cancelled) (completion-test/picking:quit!))
  (with-sources (list buffer-picker:buffers notes-source)
    (lambda ()
      (test-user:press! "C-x b")
      (completion-test/picking:choices)
      (test-user:type! "b ")
      (check-equal? (list "" "Buffers") (list (completion-test/sessions:input) (completion:narrowed (completion-test/picking:session))))
      (check-equal? '(cancelled) (completion-test/picking:quit!)))))

(test "with completion:any-order as the styles, C-x b matches the words of its input in any order"
  (only! "notes" "other notes")
  (options:set! completion:styles (list completion:any-order))
  (test-user:press! "C-x b")
  (test-user:type! "notes other")
  (check-equal? '("other notes") (completion-test/picking:choices))
  (check-equal? '(cancelled) (completion-test/picking:quit!))
  (options:unset! completion:styles))

(test "C-x 4 b shows the buffer chosen in another view, which it selects; on the selected view's own buffer that is a second view of it"
  (only! "notes" "elsewhere")
  (layout:switch-to-buffer (buffers:find "notes"))
  (let ([first (view)])
    (test-user:press! "C-x 4 b")
    (test-user:type! "elsewhere")
    (completion-test/picking:choices)
    (test-user:press! "RET")
    (check-equal? (list "notes" "elsewhere" #f) (list (buffers:name (views:buffer first)) (shown-name) (eq? first (view))))
    (test-user:press! "C-x 0")
    (test-user:press! "C-x 4 b")
    (test-user:type! "notes")
    (completion-test/picking:choices)
    (test-user:press! "RET")
    (check-equal? (list "notes" "notes" #f) (list (buffers:name (views:buffer first)) (shown-name) (eq? first (view))))
    (test-user:press! "C-x 0")))

(test "b and k act on a buffer chosen in any read of buffers"
  (check-eq? buffer-picker:switch-to-buffer (keys:lookup-in (list completion:buffer-action-keymap) "b"))
  (check-eq? buffer-picker:kill-buffer (keys:lookup-in (list completion:buffer-action-keymap) "k")))
