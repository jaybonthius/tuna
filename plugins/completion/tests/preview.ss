(import (tuna) (test) (test-user) (test-runner) (saved) (buffers) (layout) (minibuffer) (completion) (completion-list) (editing) (completion-test sessions))

(saved:define-saved h '() list?)

(define seen '())

(define (show v) (set! seen (cons v seen)))

(define (end v) (set! seen (cons (list 'end v) seen)))

(define (previewed) (completion:source (candidates (vector (cons "a" 1) (cons "b" 2))) (preview show end)))

(test "show is called at each selection change, with #f when nothing is selected, and end with #f once a quit read has ended"
  (set! seen '())
  (saved:set! h '())
  (let ([r (completion-test/sessions:start! (lambda () (completion:read "? " (list (previewed)) h)))])
    (test-user:press! "C-n")
    (test-user:type! "zz")
    (test-user:press! "C-g")
    (check-raises cancelled? (completion-test/sessions:result r))
    (check-equal? '(1 2 #f (end #f)) (reverse seen))))

(test "end is called with the chosen candidate's value"
  (set! seen '())
  (saved:set! h '())
  (let ([r (completion-test/sessions:start! (lambda () (completion:read "? " (list (previewed)) h)))])
    (test-user:press! "C-n RET")
    (check-equal? 2 (completion-test/sessions:result r))
    (check-equal? '(1 2 (end 2)) (reverse seen))))

(test "another source's candidate chosen, or an input that names none, ends the preview with #f"
  (set! seen '())
  (saved:set! h '("b"))
  (let* ([other-seen '()]
         [r (completion-test/sessions:start!
              (lambda ()
                (completion:read "? "
                  (list (previewed) (completion:source (candidates (vector (cons "c" 3))) (preview show (lambda (v) (set! other-seen (cons v other-seen))))))
                  h)))])
    (test-user:press! "C-n C-n RET")
    (check-equal? 3 (completion-test/sessions:result r))
    (check-equal? '(2 1 #f 3 (end #f)) (reverse seen))
    (check-equal? '(3) other-seen))
  (set! seen '())
  (saved:set! h '("b"))
  (let ([r (completion-test/sessions:start! (lambda () (completion:read-or-input "? " (list (previewed)) h)))])
    (test-user:type! "q")
    (test-user:press! "RET")
    (check-equal? "q" (completion-test/sessions:result r))
    (check-equal? '(2 #f (end #f)) (reverse seen))))

(test "with preview-delay, show is called once the selection has rested that long, so a selection left at once is never shown"
  (set! seen '())
  (saved:set! h '("b"))
  (let ([r (completion-test/sessions:start!
             (lambda ()
               (completion:read "? " (list (completion:source (candidates (vector (cons "a" 1) (cons "b" 2))) (preview show end) (preview-delay 0.2))) h)))])
    (test-user:press! "C-n")
    (check-equal? '() seen)
    (test-runner:wait-until (lambda () (pair? seen)))
    (check-equal? '(1) (reverse seen))
    (test-user:press! "C-g")
    (check-raises cancelled? (completion-test/sessions:result r))
    (check-equal? '(1 (end #f)) (reverse seen))))

(test "completion:preview-place checks what it is given"
  (let* ([v (layout:selected-view)] [b (buffers:make "placed" "one\n")])
    (check-raises (lambda (c) (equal? "not a position in the buffer" (condition-message c))) (completion:preview-place v b -1 '()))
    (check-raises (lambda (c) (equal? "not a list of ranges in the buffer" (condition-message c))) (completion:preview-place v b 1 '((1 1000))))
    (check-raises (lambda (c) (equal? "not a view" (condition-message c))) (completion:preview-place 'v b 1 '()))
    (buffers:kill! b)))
