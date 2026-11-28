(import (tuna) (test) (test-runner) (timers) (buffers) (document) (buffers-test marks) (buffers-test))

(buffers:define-layer hl (priority 10))
(buffers:define-layer low)
(buffers:define-layer evap (evaporate) (sticky both))
(buffers:define-layer keyed (keymap 'keys))
(buffers:define-layer responses (travels) (sticky after))
(buffers:define-layer locked (read-only) (sticky before))

(define (spans-of layer b) (buffers-test:all-spans layer b))

(test "a layer is made on first use, one per buffer, type and key"
  (let* ([t (buffers-test:fresh "0123456789\n")] [h (buffers:layer t hl)])
    (check-equal? (list #t #t #f) (list (eq? h (buffers:layer t hl)) (buffers:layer? h) (buffers:layer? hl)))
    (check (not (eq? h (buffers:layer t hl 'view1))))
    (check-raises (buffers-test:raised-with? 'buffers:layer "not a defined layer type" '(nothing)) (buffers:layer t 'nothing))))

(test "define-layer's clauses are checked where it is written"
  (check-equal? '("invalid clause" (sticky up))
    (guard (c [(syntax-violation? c) (list (condition-message c) (syntax->datum (syntax-violation-subform c)))])
      (load-module! '(buffers-test layer-sticky-up)))))

(test "set-spans! replaces the spans within a range, keeping the parts of spans crossing its edges; spans overlap a range by start"
  (let* ([t (buffers-test:fresh "0123456789\n")] [h (buffers:layer t hl)])
    (check-equal? #t (buffers:set-spans! h 0 12 '((2 4 a) (5 8 b) (8 8 c))))
    (check-equal? '(((2 4 a) (5 8 b) (8 8 c)) () ((8 8 c))) (list (spans-of h t) (buffers:spans h 4 5) (buffers:spans h 8 8)))
    (buffers:set-spans! h 3 6 '((4 5 new)))
    (check-equal? '((2 3 a) (4 5 new) (6 8 b) (8 8 c)) (spans-of h t))))

(test "spans move with edits by their stickiness, an emptied one stays unless its type evaporates, and remove-span! takes the equal ones"
  (let* ([t (buffers-test:fresh "0123456789\n")] [h (buffers:layer t hl)] [e (buffers:layer t evap)])
    (buffers:set-spans! h 0 12 '((2 3 a) (4 5 new) (6 8 b) (8 8 c)))
    (buffers:replace! t 3 3 "xx")
    (check-equal? '((2 3 a) (6 7 new) (8 10 b) (10 10 c)) (spans-of h t))
    (buffers:replace! t 2 8 "")
    (check-equal? '((2 2 a) (2 2 new) (2 4 b) (4 4 c)) (spans-of h t))
    (buffers:add-span! e 2 3 'one)
    (check-equal? '(((2 3 one)) ((2 3 one)) () ((2 4 b)))
      (list (buffers:spans-at e 2) (buffers:spans-at e 3) (buffers:spans-at h 2) (buffers:spans-at h 3)))
    (buffers:replace! t 2 3 "")
    (check-equal? '(() ((2 2 a) (2 2 new) (2 3 b) (3 3 c))) (list (spans-of e t) (spans-of h t)))
    (buffers:remove-span! h 'new)
    (check-equal? '((2 2 a) (2 3 b) (3 3 c)) (spans-of h t))))

(test "a buffer's layers for no key and for a key come lowest priority first, each with its type's priority and keymap"
  (let ([t (buffers-test:fresh "x\n")])
    (for-each (lambda (type) (buffers:layer t type)) (list hl evap))
    (buffers:layer t low 'view1)
    (buffers:layer t low 'view2)
    (check-equal? (list (list (buffers:layer t evap) (buffers:layer t hl))
                        (list (buffers:layer t evap) (buffers:layer t low 'view1) (buffers:layer t hl)))
                  (list (buffers:layers t) (buffers:layers t 'view1)))
    (check-equal? '(0 0 10) (map buffers:layer-priority (buffers:layers t 'view1)))
    (check-raises (buffers-test:raised-with? 'buffers:layer-priority "not a layer" '(hl)) (buffers:layer-priority 'hl))
    (check-equal? '(#f keys) (list (buffers:layer-keymap (buffers:layer t hl)) (buffers:layer-keymap (buffers:layer t keyed))))))

(test "spans a job computed at an older version move through the edits since"
  (let* ([t (buffers-test:fresh "abcd\n")] [h (buffers:layer t hl)] [v (buffers:version t)])
    (buffers:replace! t 1 1 "abc")
    (check-equal? #t (buffers:set-spans! h 0 4 '((1 3 old)) v))
    (check-equal? '((4 6 old)) (spans-of h t))))

(test "at idle a log keeps its last thousand edits, anchors moved first still follow, and spans from before the log return #f"
  (let* ([t (buffers-test:fresh "abc\n")] [early (buffers:anchor t 3)])
    (do ([i 0 (+ i 1)]) ((= i 1500)) (buffers:replace! t 1 1 "x"))
    (check-equal? 1500 (length (buffers:edits-since t 0)))
    (timers:set-idle! #t)
    (test-runner:wait-until (lambda () (not (buffers:edits-since t 0))))
    (timers:set-idle! #f)
    (check-equal? '(#f #f 1000) (list (buffers:edits-since t 0) (buffers:edits-since t 499) (length (buffers:edits-since t 500))))
    (check-equal? '(#f 1003 1503) (list (buffers:map-position t 3 0) (buffers:map-position t 3 500) (buffers:anchor-position early)))
    (check-equal? #f (buffers:set-spans! (buffers:layer t hl) 0 3 '((1 2 a)) 10))))

(define (spans-in piece)
  (let ([b (buffers-test:fresh "\n")])
    (buffers:insert! b 1 piece)
    (spans-of (buffers:layer b responses) b)))

(define (undo! b edit)
  (let ([start (buffers:edit-start edit)])
    (buffers:splice! b start (+ start (buffers:piece-length (buffers:edit-inserted edit))) (buffers:edit-removed edit))))

(test "travelling spans are content: setting them is an edit, a piece carries them, edits carry pieces, and undo brings them back"
  (let* ([t (buffers-test:fresh "Hello world.\n")] [r (buffers:layer t responses)])
    (buffers:add-span! r 1 6 'gpt)
    (check-equal? 1 (buffers:version t))
    (let ([e (car (buffers:edits-since t 0))])
      (check-equal? '(() ((1 6 gpt))) (list (spans-in (buffers:edit-removed e)) (spans-in (buffers:edit-inserted e)))))
    (buffers:replace! t 6 6 "!")
    (buffers:replace! t 3 3 "y")
    (check-equal? '((1 8 gpt)) (spans-of r t))
    (let ([piece (buffers:piece t 2 5)])
      (check-equal? '(#t #f 3 "eyl" ("eyl"))
        (list (buffers:piece? piece) (buffers:piece? "ell") (buffers:piece-length piece) (buffers:piece-text piece)
              (document:datums (buffers:piece-document piece))))
      (check-equal? '((1 4 gpt)) (spans-in piece))
      (let ([e (buffers:replace! t 2 5 "")])
        (check-equal? '(((1 4 gpt)) ()) (list (spans-in (buffers:edit-removed e)) (spans-in (buffers:edit-inserted e)))))
      (check-equal? '("Hlo! world.\n" ((1 5 gpt))) (list (document:text (buffers:document t)) (spans-of r t)))
      (check-equal? 12 (buffers:insert! t 9 piece))
      (buffers:replace! t 9 9 "plain")
      (check-equal? '("Hlo! worplaineylld.\n" ((1 5 gpt) (14 17 gpt))) (list (document:text (buffers:document t)) (spans-of r t))))
    (for-each (lambda (e) (undo! t e)) (reverse (buffers:edits-since t 3)))
    (check-equal? '("Heyllo! world.\n" ((1 8 gpt))) (list (document:text (buffers:document t)) (spans-of r t)))))

(test "an edit that sets travelling spans moves no anchor, and undoing it restores the spans"
  (let* ([t (buffers-test:fresh "Heyllo! world.\n")] [r (buffers:layer t responses)] [a (buffers:anchor t 3)])
    (buffers:add-span! r 1 8 'gpt)
    (buffers:set-spans! r 2 4 '((2 4 x)))
    (let ([spans-edit (car (reverse (buffers:edits-since t 0)))])
      (check-equal? '(((1 2 gpt) (2 4 x) (4 8 gpt)) 3 #t #f)
        (list (spans-of r t) (buffers:anchor-position a)
              (eq? (buffers:piece-document (buffers:edit-removed spans-edit)) (buffers:piece-document (buffers:edit-inserted spans-edit)))
              (buffers:edit-moves? spans-edit)))
      (undo! t spans-edit)
      (check-equal? '(((1 8 gpt)) 3) (list (spans-of r t) (buffers:anchor-position a))))))

(test "spans a piece brings for a layer type the buffer has no layer of make that layer"
  (let ([e (buffers-test:fresh "abc\n")]
        [tagged (let ([x (buffers-test:fresh "xy\n")]) (buffers:add-span! (buffers:layer x responses) 1 3 'tag) (buffers:piece x 1 3))])
    (check-equal? '() (buffers:layers e))
    (buffers:replace! e 1 1 tagged)
    (check-equal? '(((1 3 tag))) (map (lambda (l) (buffers:spans l 0 7)) (buffers:layers e)))))

(test "a piece checks its arguments"
  (let ([t (buffers-test:fresh "abc\n")])
    (check-raises (buffers-test:raised? 'buffers:piece "not a buffer") (buffers:piece "t" 1 2))
    (check-raises (buffers-test:raised? 'buffers:piece "the start is after the end") (buffers:piece t 3 1))
    (check-raises (buffers-test:raised? 'buffers:piece "not a position in the buffer") (buffers:piece t 0 99))
    (check-raises (buffers-test:raised? 'buffers:piece-document "not a piece") (buffers:piece-document "x"))
    (check-raises (buffers-test:raised? 'buffers:piece-length "not a piece") (buffers:piece-length "x"))
    (check-raises (buffers-test:raised? 'buffers:piece-text "not a piece") (buffers:piece-text "x"))))

(test "a read-only span refuses an edit that touches it or inserts where it would take the text, saying the buffer's text is read-only; splice! asks no layer"
  (let* ([t (buffers-test:fresh "Hlo! world.\n")] [g (buffers:layer t locked)]
         [try (lambda (thunk) (guard (c [(buffers:refused? c) (list (condition-message c) (condition-irritants c))]) (thunk)))])
    (buffers:add-span! g 4 6 'locked)
    (check-equal? (make-list 3 (list (string-append "the text of " (buffers:name t) " is read-only") '()))
      (list (try (lambda () (buffers:replace! t 5 5 "x"))) (try (lambda () (buffers:replace! t 4 4 "x")))
            (try (lambda () (buffers:replace! t 3 5 "")))))
    (check-equal? '(#t #t #f) (list (buffers:refuses-text? t 5 5) (buffers:refuses-text? t 3 5) (buffers:refuses-text? t 7 7)))
    (buffers:replace! t 6 6 "x")
    (buffers:replace! t 2 4 "")
    (buffers:splice! t 3 3 (document:from-datum "s"))
    (check-equal? '((2 5 locked)) (spans-of g t))))

(test "a layer keeps its type's clauses while the type is undefined, and has no keymap then"
  (let* ([t (buffers-test:fresh "abcdefgh\n")] [m (buffers:layer t buffers-test/marks:marks)])
    (buffers:add-span! m 3 5 'm)
    (check-equal? 'mark-keys (buffers:layer-keymap m))
    (unload-owner! (module-owner '(buffers-test marks)))
    (buffers:replace! t 5 5 "zz")
    (check-equal? '(((3 7 m)) #f) (list (spans-of m t) (buffers:layer-keymap m)))
    (buffers:splice! t 3 7 (document:from-datum))
    (check-equal? '() (spans-of m t))
    (load-module! '(buffers-test marks))
    (check-equal? 'mark-keys (buffers:layer-keymap m))))
