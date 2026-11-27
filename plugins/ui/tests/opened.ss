(import (tuna) (test) (test-runner) (test-user) (layout) (views) (buffers) (document) (modes) (editing) (isearch) (ui) (ui-test))

(define view ui-test:view)
(define visible ui-test:visible)

(buffers:define-kind header)
(buffers:define-kind status (content nodes))

(define (status-datum . sections) (apply status '() (header '() "Head: main\n") sections))
(define (hunk heading . lines) (apply ui:section `((type . hunk) (value . ,heading)) heading lines))
(define (file path . hunks) (apply ui:section `((type . file) (value . ,path)) (string-append "modified " path) hunks))
(define (fa) (file "a" (hunk "@@ a @@" "-a1" "+a2")))
(define (fb) (file "b" (hunk "@@ b @@" "-b1" "+b2")))
(define (fb2) (file "b" (hunk "@@ b @@" "-b1" "+b2" "+b3")))
(define (fc) (file "c" (hunk "@@ c @@" "-c1" "+c2")))
(define (unstaged n . files) (apply ui:section '((type . unstaged)) (format "Unstaged changes (~a)" n) files))
(define (staged . files) (apply ui:section '((type . staged)) "Staged" files))

(define b (buffers:make "*st*" (status-datum (unstaged 3 (fa) (fb) (fc)) (staged))))
(buffers:set-silent! b #t)
(modes:set-major-mode ui:section-mode b)
(ui-test:show! b)

(define v (view))

(define (rebuild! . sections) (buffers:reconcile! b (document:token (buffers:document b) 0) (cddr (apply status-datum sections))))
(define (find-section . identity) (ui:find-section b identity))
(define (hide-b!) (ui:hide-section! v (find-section '(file . "b") '(unstaged . #f))))
(define (b-hidden?) (ui:section-hidden? v (find-section '(file . "b") '(unstaged . #f))))
(define (into-b-hunk!) (views:set-point! v (+ 3 (ui:section-heading-start (find-section '(hunk . "@@ b @@") '(file . "b") '(unstaged . #f))))))

(define b-shown '("Head: main" "Unstaged changes (3)" "modified a" "@@ a @@" "-a1" "+a2" "modified b" "@@ b @@" "-b1" "+b2" "modified c" "@@ c @@" "-c1" "+c2" "Staged"))
(define b2-shown '("Head: main" "Unstaged changes (3)" "modified a" "@@ a @@" "-a1" "+a2" "modified b" "@@ b @@" "-b1" "+b2" "+b3" "modified c" "@@ c @@" "-c1" "+c2" "Staged"))
(define b-hidden '("Head: main" "Unstaged changes (3)" "modified a" "@@ a @@" "-a1" "+a2" "modified b…" "modified c" "@@ c @@" "-c1" "+c2" "Staged"))

(test "a section opened because a cursor came into its hidden body stays open across a refresh that edits inside it"
  (test-user:settle)
  (hide-b!)
  (check-equal? b-hidden (visible v))
  (into-b-hunk!)
  (test-user:settle)
  (check-equal? (list b-shown 96) (list (visible v) (views:point v)))
  (rebuild! (unstaged 3 (fa) (fb2) (fc)) (staged))
  (test-user:settle)
  (check-equal? (list b2-shown 96 #f) (list (visible v) (views:point v) (b-hidden?))))

(test "hiding it again records that, so the next refresh keeps it hidden"
  (hide-b!)
  (rebuild! (unstaged 3 (fa) (fb) (fc)) (staged))
  (check-equal? (list b-hidden #t) (list (visible v) (b-hidden?))))

(test "a search that ends at a match in the hidden body leaves the section open, and a refresh that edits inside it keeps it open"
  (views:set-point! v 1)
  (test-user:press! "C-s b 2 RET")
  (check-equal? (list b-shown 112 #f) (list (visible v) (views:point v) (b-hidden?)))
  (rebuild! (unstaged 3 (fa) (fb2) (fc)) (staged))
  (check-equal? (list b2-shown 112 #f) (list (visible v) (views:point v) (b-hidden?))))

(test "a search cancelled in a hidden body leaves the section hidden"
  (hide-b!)
  (views:set-point! v 1)
  (check (for-all cancelled? (test-runner:reports-during (lambda () (test-user:press! "C-s b 2 C-g")))))
  (check-equal? (list #t 2) (list (b-hidden?) (views:point v))))

(test "a search that moves from one match to another in the same hidden body and ends there leaves it open"
  (test-user:press! "C-s + C-s C-s RET")
  (check-equal? "+b" (document:text (buffers:document b) (- (views:point v) 1) (+ (views:point v) 1)))
  (rebuild! (unstaged 3 (fa) (fb) (fc)) (staged))
  (check-equal? (list b-shown #f) (list (visible v) (b-hidden?))))

(test "a search that passes through a hidden body and ends elsewhere leaves it hidden"
  (hide-b!)
  (rebuild! (unstaged 3 (fa) (fb2) (fc)) (staged))
  (views:set-point! v 1)
  (test-user:press! "C-s + C-s C-s C-s RET")
  (check-equal? (list #t 155) (list (b-hidden?) (views:point v)))
  (rebuild! (unstaged 3 (fa) (fb) (fc)) (staged))
  (check-equal? (list b-hidden #t) (list (visible v) (b-hidden?))))

(test "a refresh between the draw that opened a section for a cursor and views' tell hides it again, and the tell then records nothing"
  (hide-b!)
  (into-b-hunk!)
  (ui-test:drawn v)
  (rebuild! (unstaged 3 (fa) (fb2) (fc)) (staged))
  (check-equal? (list 79 #t) (list (views:point v) (b-hidden?)))
  (test-user:settle)
  (check-equal? (list 79 #t) (list (views:point v) (b-hidden?)))
  (rebuild! (unstaged 3 (fa) (fb) (fc)) (staged))
  (test-user:settle)
  (check-equal? (list b-hidden 79 #t) (list (visible v) (views:point v) (b-hidden?))))
