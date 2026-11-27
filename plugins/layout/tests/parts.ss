(import (tuna) (test) (test-user) (layout) (layout-split) (views) (buffers) (document) (commands)
        (layout-test parts) (layout-test boxes))

(define notes (buffers:make "notes" "one\ntwo\nthree\n"))
(define mail (buffers:make "mail" "Dear Harpo,\n"))

(define (fresh b) (views:make b))

(define (doc) (buffers:document layout:buffer))

(define (node-at i) (document:token (doc) i))

(define (on-thread thunk)
  (let ([result #f])
    (join-task
      (fork-task
        (lambda (restore)
          (set! result (guard (c [(and (who-condition? c) (message-condition? c)) (list (condition-who c) (condition-message c))])
                         (thunk))))))
    result))

(define (start-with-echo!)
  (let ([a (fresh notes)] [b (fresh mail)] [c (fresh notes)])
    (layout-test/parts:set-parts!
      (layout-split:container '((direction . row)) (layout-test/parts:atom a)
        (layout-test/boxes:box '() (layout-test/parts:atom b) (layout-test/parts:atom c))))
    (let ([echo (layout-test/parts:place-echo! (buffers:make (buffers:free-name "*Echo*") ""))])
      (test-user:settle)
      (values a b c echo))))

(test "the user's commands refuse to delete a locked part, and delete-part! refuses the root and what is not a node"
  (let-values ([(a b c echo) (start-with-echo!)])
    (layout:select! echo)
    (check-equal? '((layout:delete-view "a locked part"))
                  (layout-test/parts:refusals-during (lambda () (commands:run layout:delete-view))))
    (check-raises (layout-test/parts:raised-with 'layout:delete-part! "the root") (layout:delete-part! (node-at 0)))
    (check-raises (layout-test/parts:raised-with 'layout:delete-part! "not a node") (layout:delete-part! 'node))
    (check-equal? '(#t #t #t #t) (map (lambda (v) (layout:deletable? (layout:view-node v))) (list a b c echo)))
    (check-equal? #f (layout:deletable? (node-at 0)))))

(test "deleting the selected view selects its level's view selected most recently, and a container left empty goes"
  (let-values ([(a b c echo) (start-with-echo!)])
    (layout:select! b)
    (layout:select! a)
    (layout:select! c)
    (layout:delete-part! (layout:view-node c))
    (check (eq? a (layout:selected-view)))
    (layout:delete-part! (layout:view-node b))
    (check-equal? (list 'layout:level (list 'layout-split:container (list 'layout:level "notes") (buffers:name (views:buffer echo))))
                  (layout-test/parts:outline))
    (check (eq? a (layout:selected-view)))))

(test "a level keeps its part: its last view cannot be deleted, by code or by C-x 0"
  (let-values ([(a b c echo) (start-with-echo!)])
    (layout:delete-part! (layout:view-node b))
    (layout:delete-part! (layout:view-node c))
    (layout:select! a)
    (check-equal? #f (layout:deletable? (layout:view-node a)))
    (check-raises (layout-test/parts:raised-with 'layout:delete-part! "the last view of its level")
                  (layout:delete-part! (layout:view-node a)))
    (check-equal? '((layout:delete-part! "the last view of its level"))
                  (layout-test/parts:refusals-during (lambda () (commands:run layout:delete-view))))))

(test "removing a placed part collapses its split, the root gives up the level left inside it, and views whose atoms left are dropped when the batch ends"
  (let*-values ([(a b c echo) (start-with-echo!)] [(ids) (map views:id (list a b c echo))])
    (layout:delete-part! (layout:view-node b))
    (layout:delete-part! (layout:view-node c))
    (layout:delete-part! (layout:view-node echo))
    (check-equal? '(layout:level "notes") (layout-test/parts:outline))
    (test-user:settle)
    (check-equal? (list a #f #f #f) (map views:find ids))))

(test "a part's title is its title attribute, else its view's buffer name, else its focused child's title"
  (let ([a (fresh notes)] [titled (fresh mail)])
    (layout-test/parts:set-parts!
      (layout-split:container '((title . "work")) (layout-test/parts:atom a) (layout-test/parts:atom titled '(title . "letters"))))
    (check-equal? "letters" (layout:part-title (layout:view-node titled)))
    (check-equal? "work" (layout:part-title (node-at 1)))
    (layout:select! titled)
    (check-equal? "notes" (layout:part-title (layout:view-node a)))
    (check-equal? "work" (layout:part-title (node-at 0)))
    (layout-test/parts:set-parts! (layout-split:container '() (layout-test/parts:atom a) (layout-test/parts:atom titled)))
    (layout:select! titled)
    (check-equal? "mail" (layout:part-title (node-at 1)))
    (layout:select! a)
    (check-equal? "notes" (layout:part-title (node-at 1)))))

(test "each kind's check refuses an edit that would leave the layout malformed"
  (let ([a (fresh notes)] [b (fresh mail)])
    (layout-test/parts:set-parts! (layout-split:container '() (layout-test/parts:atom a) (layout-test/parts:atom b)))
    (let ([before (layout-test/parts:tree)] [refused? (lambda (e) (buffers:refused? e))])
      (check-raises (lambda (e) (and (message-condition? e) (string=? "the content does not fit here" (condition-message e))))
                    (buffers:replace! layout:buffer 2 2 "text"))
      (check-raises refused? (buffers:replace! layout:buffer 2 2 '(buffers:text () "text")))
      (check-raises refused? (buffers:replace! layout:buffer 2 2 (views:view '((buffer . "notes")))))
      (check-raises refused? (buffers:replace! layout:buffer 2 2 (layout-split:container '())))
      (check-raises refused? (buffers:replace! layout:buffer 1 (- (document:length (doc)) 1) ""))
      (check-raises refused? (buffers:replace! layout:buffer 2 2 (layout-test/parts:atom a)))
      (check-raises refused? (layout-test/parts:set-parts! (layout-split:container '() (layout-test/parts:atom a) (layout-test/parts:atom a))))
      (check-raises refused?
        (buffers:replace! layout:buffer 1 (- (document:length (doc)) 1)
          (document:from-datum (layout-test/parts:atom a) (layout-test/parts:atom b))))
      (check-raises refused? (layout-test/parts:set-parts! (layout:level '() (layout-test/parts:atom a))))
      (check-raises refused?
        (layout-test/parts:set-parts!
          (layout-split:container '() (layout:level '() (layout-test/parts:atom a) (layout-test/parts:atom b)))))
      (check-raises refused?
        (layout-test/parts:set-parts!
          (layout-split:container '() (layout:level '() (layout:level '() (layout-test/parts:atom a))) (layout-test/parts:atom b))))
      (check-equal? before (layout-test/parts:tree)))))

(test "the layout buffer is never killed"
  (check-equal? #f (buffers:kill! layout:buffer))
  (check (buffers:live? layout:buffer))
  (check-equal? #f (buffers:kill! layout:popups-buffer)))

(test "a kind whose neighbour clause names a part that is not its child raises"
  (let ([a (fresh notes)] [d (fresh mail)])
    (layout-test/parts:set-parts!
      (layout-split:container '((direction . row)) (layout-test/parts:atom a) (layout-test/boxes:stray '() (layout-test/parts:atom d))))
    (check-raises (layout-test/parts:raised-with 'layout:neighbour "a kind's neighbour is not a child of its container")
                  (layout:neighbour d (layout:direction left)))))

(test "a part removed by one edit and put back by another in the same batch keeps its view"
  (let ([a (fresh notes)] [b (fresh mail)])
    (layout-test/parts:set-parts! (layout-split:container '((direction . column)) (layout-test/parts:atom a) (layout-test/parts:atom b)))
    (test-user:settle)
    (let ([e (buffers:replace! layout:buffer 2 3 "")])
      (buffers:splice! layout:buffer 2 2 (buffers:edit-removed e)))
    (test-user:settle)
    (check (eq? a (car (layout:views))))))

(test "a view dropped with its part comes back as a new view, numbered as its atom, when its atom is put back"
  (let ([a (fresh notes)] [b (fresh mail)])
    (layout-test/parts:set-parts! (layout-split:container '((direction . column)) (layout-test/parts:atom a) (layout-test/parts:atom b)))
    (layout:select! a)
    (test-user:settle)
    (let ([id (views:id a)] [e (buffers:replace! layout:buffer 2 3 "")])
      (test-user:settle)
      (check-equal? #f (views:find id))
      (check (eq? b (layout:selected-view)))
      (buffers:splice! layout:buffer 2 2 (buffers:edit-removed e))
      (test-user:settle)
      (let ([back (views:find id)])
        (check (views:view? back))
        (check (not (eq? back a)))
        (check-equal? (list back b) (layout:views))
        (check-equal? "notes" (buffers:name (views:buffer back)))))))

(test "set-part-attribute! sets or removes one attribute of a part, keeping the others, and checks its arguments"
  (let ([a (fresh notes)] [b (fresh mail)])
    (layout-test/parts:set-parts!
      (layout-split:container '((direction . row)) (layout-test/parts:atom a '(weight . 2)) (layout-test/parts:atom b)))
    (layout:set-part-attribute! (layout:view-node a) 'title "first")
    (check-equal? '((weight . 2) (title . "first")) (cddr (layout-test/parts:attributes-of a)))
    (let ([version (buffers:version layout:buffer)])
      (layout:set-part-attribute! (layout:view-node a) 'title "first")
      (check-equal? version (buffers:version layout:buffer)))
    (layout:set-part-attribute! (layout:view-node a) 'title #f)
    (check-equal? '((weight . 2)) (cddr (layout-test/parts:attributes-of a)))
    (layout:set-part-attribute! (node-at 1) 'title "split")
    (check-equal? "split" (layout:part-title (node-at 1)))
    (check-raises (layout-test/parts:raised-with 'layout:set-part-attribute! "not a symbol")
                  (layout:set-part-attribute! (layout:view-node a) "title" "x"))
    (check-raises (lambda (e) (and (who-condition? e) (eq? 'layout:set-part-attribute! (condition-who e))))
                  (layout:set-part-attribute! 'node 'title "x"))
    (check-raises (lambda (e) (and (message-condition? e) (string=? "not plain data" (condition-message e))))
                  (layout:set-part-attribute! (layout:view-node a) 'title (lambda () 1)))))

(test "level-of gives a view's level, and takes a view"
  (let ([a (fresh notes)])
    (layout-test/parts:set-parts! (layout-test/parts:atom a))
    (check-equal? 0 (document:node-start (layout:level-of a)))
    (check-raises (layout-test/parts:raised-with 'layout:level-of "not a view") (layout:level-of 'notes))))

(test "layout's procedures run on the main thread only"
  (check-equal? '(layout:selected-view "not on the main thread") (on-thread layout:selected-view))
  (check-equal? '(layout:screen "not on the main thread") (on-thread (lambda () (layout:screen (test-user:client)))))
  (let ([v (layout:selected-view)])
    (check-equal? '(layout:select! "not on the main thread") (on-thread (lambda () (layout:select! v)))))
  (check-equal? '(layout:views "not on the main thread") (on-thread layout:views)))
