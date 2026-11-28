(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (modes) (buffers) (document) (views)
        (layout) (layout-split) (files) (projects) (editing) (jump-history) (completion) (completion-list) (minibuffer)
        (outline) (outline-picker) (completion-test sessions) (completion-test picking) (outline-picker-test reading) (minibuffer-test reading))

(define (home path) (string-append (getenv "HOME") "/" path))

(define (write-file! path text)
  (call-with-output-file (home path) (lambda (p) (put-string p text)) 'replace))

(tables:define-table toy-keymap)
(hooks:define-hook toy-hook)
(modes:define-major-mode toy-mode (keymap toy-keymap) (hook toy-hook))

;; Each line "KIND NAME" of a toy buffer is an entry, except in quiet.toy,
;; whose sources give no outline.
(define (toy-outline b)
  (and (eq? (modes:major-mode b) toy-mode)
       (not (string=? (buffers:name b) "quiet.toy"))
       (let ([doc (buffers:document b)])
         (outline:make-outline b (buffers:version b)
           (let loop ([line 1] [acc '()])
             (if (> line (document:line doc (document:length doc)))
                 (reverse acc)
                 (let* ([start (editing:line-position b line)]
                        [end (if (< line (document:line doc (document:length doc)))
                                 (- (document:line-start doc (+ line 1)) 1)
                                 (document:length doc))]
                        [text (document:text doc start end)]
                        [space (let find ([i 0]) (cond [(= i (string-length text)) #f]
                                                       [(char=? (string-ref text i) #\space) i]
                                                       [else (find (+ i 1))]))])
                   (loop (+ line 1)
                         (if space
                             (cons (outline:make-entry (substring text (+ space 1) (string-length text))
                                                       (string->symbol (substring text 0 space))
                                                       start end (+ start space 1))
                                   acc)
                             acc)))))))))

(hooks:add! outline:sources toy-outline)

(mkdir (home "shop"))
(mkdir (home "elsewhere"))
(write-file! "shop/.project" "")
(write-file! "shop/src.toy" "function alpha\nvariable beta\n")
(write-file! "shop/other.toy" "function z\n")
(write-file! "shop/quiet.toy" "function hidden\n")
(write-file! "shop/notes.txt" "function plain\n")
(write-file! "elsewhere/far.toy" "function far\n")
(options:set! projects:extra-root-markers '(".project"))

(define (visit path)
  (let ([b (files:visit (home path))])
    (unless (string=? (substring path (- (string-length path) 4) (string-length path)) ".txt")
      (modes:set-major-mode toy-mode b))
    b))

(define src (visit "shop/src.toy"))
(define other (visit "shop/other.toy"))
(define quiet (visit "shop/quiet.toy"))
(define notes (visit "shop/notes.txt"))
(define far (visit "elsewhere/far.toy"))

(define view outline-picker-test/reading:view)
(define place-of outline-picker-test/reading:place-of)
(define here outline-picker-test/reading:here)
(define go! outline-picker-test/reading:go!)
(define session outline-picker-test/reading:session)
(define rows outline-picker-test/reading:rows)
(define quit! outline-picker-test/reading:quit!)

(define (choose! keys) (completion-test/picking:press-until-ended! keys outline-picker:project-entry))

(test "M-g I reads the entries of the project's buffers of the current buffer's mode, the prompt naming their count and the project; another mode's buffer and one with no outline are left out"
  (go! src 2 0)
  (test-user:press! "M-g I")
  (check-equal? '(("Functions: other.toy" "z") ("Functions: src.toy" "alpha") ("Variables: src.toy" "beta")) (rows))
  (check-equal? '("Go to item (3 buffers, Project shop): ") (minibuffer-test/reading:questions))
  (quit!))

(test "each group names its kind and its buffer, and a kind's narrow character shows that kind in every buffer"
  (go! src 2 0)
  (test-user:press! "M-g I")
  (rows)
  (test-user:type! "f ")
  (check-equal? '(("Functions: other.toy" "z") ("Functions: src.toy" "alpha")) (rows))
  (quit!))

(test "with C-u it reads every live buffer of the mode, in any project"
  (go! src 2 0)
  (test-user:press! "C-u M-g I")
  (check-equal? '(("Functions: far.toy" "far") ("Functions: other.toy" "z") ("Functions: src.toy" "alpha")
                  ("Variables: src.toy" "beta"))
                (rows))
  (check-equal? '("Go to item (4 buffers): ") (minibuffer-test/reading:questions))
  (quit!))

(test "in no project it reads the current buffer alone"
  (go! far 1 0)
  (test-user:press! "M-g I")
  (check-equal? '(("Functions: far.toy" "far")) (rows))
  (check-equal? '("Go to item (1 buffer): ") (minibuffer-test/reading:questions))
  (quit!))

(test "C-n over another buffer's entry previews that buffer in the starting view, and C-g puts the view back"
  (go! src 2 0)
  (let ([start (view)])
    (test-user:press! "M-g I")
    (rows)
    (test-runner:wait-until (lambda () (equal? '("other.toy" 1 9) (place-of start))))
    (test-user:press! "C-n")
    (test-runner:wait-until (lambda () (equal? '("src.toy" 1 9) (place-of start))))
    (quit!)
    (check-equal? '("src.toy" 2 0) (place-of start))))

(test "choosing an entry of a buffer shown nowhere shows it in the selected view and records the place left"
  (go! src 2 0)
  (test-user:press! "M-g I")
  (test-user:type! "z")
  (rows)
  (choose! "RET")
  (check-equal? '("other.toy" 1 9) (here))
  (test-user:press! "M-,")
  (check-equal? '("src.toy" 2 0) (here)))

(test "choosing an entry of a buffer another view shows selects that view, puts point on the entry and records the place that view left"
  (go! src 2 0)
  (test-user:press! "C-x 2")
  (let* ([start (view)] [other-view (find (lambda (v) (not (eq? v start))) (layout:views))])
    (views:set-buffer! other-view other)
    (views:set-point! other-view (editing:line-position other 1 4))
    (test-user:press! "M-g I")
    (test-user:type! "z")
    (rows)
    (choose! "RET")
    (check (eq? other-view (view)))
    (check-equal? '("other.toy" 1 9) (here))
    (check-equal? '("src.toy" 2 0) (place-of start))
    (test-user:press! "M-,")
    (check-equal? '("other.toy" 1 4) (here)))
  (layout:reset-layout))
