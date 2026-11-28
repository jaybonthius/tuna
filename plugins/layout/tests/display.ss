(import (tuna) (test) (test-user) (layout) (layout-split) (views) (buffers) (commands) (hooks) (options) (tables) (keys)
        (layout-test parts))

(define named layout-test/parts:named)
(define atom layout-test/parts:atom)
(define name-of layout-test/parts:name-of)

(define (pager? b) (string=? (buffers:name b) "*Pager*"))

(options:set! layout:display-action layout-split:display-right)
(tables:set! layout:display-rules pager? layout-split:display-below)

(define (fresh-name name) (buffers:make (buffers:free-name name) ""))

(define (start! . names)
  (let ([vs (map (lambda (n) (views:make (fresh-name n))) names)])
    (layout-test/parts:set-parts!
      (if (null? (cdr vs)) (atom (car vs)) (apply layout-split:container '((direction . row)) (map atom vs))))
    (layout:select! (car vs))
    vs))

(define (shown) (map (lambda (v) (cons (views:id v) (name-of v))) (layout:views)))

(test "a configuration's display action wins over the one layout-split sets as it loads"
  (check (eq? layout-split:display-right (layout:display-action))))

(test "display-buffer shows a buffer without selecting it; a buffer already shown is shown where it is"
  (let* ([first (car (start! "scratch"))] [notes (fresh-name "notes")] [v (layout:display-buffer notes)])
    (check-equal? (list 'layout:level (list 'layout-split:container (name-of first) (buffers:name notes)))
                  (layout-test/parts:outline))
    (check (eq? first (layout:selected-view)))
    (check (eq? v (layout:display-buffer notes)))
    (check-equal? #f (layout:reuse-view (fresh-name "mail")))
    (check (eq? v (layout:reuse-view notes)))))

(test "a rule whose predicate holds places the buffer first"
  (let* ([first (car (start! "scratch"))] [pager (or (buffers:find "*Pager*") (buffers:make "*Pager*" "Pager.\n"))])
    (layout:display-buffer pager)
    (check-equal? (list 'layout:level (list 'layout-split:container (name-of first) "*Pager*")) (layout-test/parts:outline))
    (check (equal? '(layout-split:container ((direction . column))) (list-head (caddr (layout-test/parts:tree)) 2)))))

(test "rules are tried newest first, then the caller's action, then the option's, then the selected view"
  (let* ([first (car (start! "scratch"))] [mail (fresh-name "mail")] [tried '()]
         [declining (lambda (name) (lambda (b) (set! tried (cons name tried)) #f))]
         [always (lambda (b) #t)] [also-always (lambda (b) #t)])
    (tables:set! layout:display-rules always (declining 'older))
    (tables:set! layout:display-rules also-always (declining 'newer))
    (options:set! layout:display-action (declining 'option))
    (check (eq? first (layout:display-buffer mail (declining 'caller))))
    (check-equal? '(newer older caller option) (reverse tried))
    (check-equal? (buffers:name mail) (name-of first))
    (check-raises (layout-test/parts:raised-with 'layout:display-buffer "an action returned what is not a view or #f")
                  (layout:display-buffer mail (lambda (b) 'nonsense)))
    (check-raises (layout-test/parts:raised-with 'layout:display-buffer "an action returned a view not in the layout")
                  (layout:display-buffer mail (lambda (b) (views:make b))))
    (check-raises (layout-test/parts:raised-with 'layout:display-buffer "not a buffer") (layout:display-buffer 'mail))
    (tables:remove! layout:display-rules always)
    (tables:remove! layout:display-rules also-always)
    (options:set! layout:display-action layout-split:display-right)))

(test "use-other-view reuses a view showing the buffer, else the view selected least recently, never the selected one or a locked one"
  (let-values ([(a b c) (apply values (start! "a" "b" "c"))])
    (options:set! layout:display-action layout:use-other-view)
    (layout:select! b)
    (layout:select! c)
    (let ([other (fresh-name "other")])
      (check (eq? a (layout:use-other-view other)))
      (check-equal? (buffers:name other) (name-of a))
      (check (eq? a (layout:use-other-view other))))
    (let* ([echo-buffer (fresh-name "*Echo*")] [echo (layout-test/parts:place-echo! echo-buffer)])
      (check (eq? a (layout:display-buffer (fresh-name "fourth"))))
      (check (eq? echo-buffer (views:buffer echo))))
    (options:set! layout:display-action layout-split:display-right)))

(test "switch-to-buffer shows the buffer in the selected view; from a locked view it displays it in the level the user was in, and selects it"
  (let-values ([(a b c) (apply values (start! "a" "b" "c"))])
    (options:set! layout:display-action layout:use-other-view)
    (layout:select! b)
    (layout:select! c)
    (let* ([notes (fresh-name "notes")] [mail (fresh-name "mail")] [echo-buffer (fresh-name "*Echo*")]
           [echo (layout-test/parts:place-echo! echo-buffer)])
      (layout:switch-to-buffer notes)
      (check (eq? c (layout:selected-view)))
      (check-equal? (buffers:name notes) (name-of c))
      (layout:select! echo)
      (layout:switch-to-buffer mail)
      (check (eq? a (layout:selected-view)))
      (check-equal? (buffers:name mail) (name-of a))
      (check (eq? echo-buffer (views:buffer echo))))
    (options:set! layout:display-action layout-split:display-right)))

(test "the page's example rule shows *compilation* below the selected view"
  (let ([first (car (start! "scratch"))])
    (define (compilation-buffer? buffer)
      (string=? (buffers:name buffer) "*compilation*"))
    (tables:set! layout:display-rules compilation-buffer? layout-split:display-below)
    (layout:select! (layout:display-buffer (or (buffers:find "*compilation*") (buffers:make "*compilation*" "make\n"))))
    (check-equal? "*compilation*" (layout-test/parts:selected-name))
    (check-equal? (list 'layout:level (list 'layout-split:container (name-of first) "*compilation*")) (layout-test/parts:outline))
    (tables:remove! layout:display-rules compilation-buffer?)))

(test "reset-layout deletes the level's other views and ends the zoom, keeping locked views, nested levels and the parts outside"
  (let-values ([(a b c d) (apply values (start! "a" "b" "c" "d"))])
    (let ([echo (layout-test/parts:place-echo! (fresh-name "*Echo*"))])
      (layout:select! b)
      (commands:run layout:zoom)
      (commands:run layout:reset-layout)
      (check-equal? (list b echo) (layout:views))
      (check-equal? #f (layout:zoomed-view))
      (check (eq? b (layout:selected-view)))
      (layout:select! echo)
      (let ([before (layout-test/parts:tree)])
        (commands:run layout:reset-layout)
        (check-equal? before (layout-test/parts:tree))
        (check (eq? b (layout:selected-view))))
      (let ([first (views:make (fresh-name "1"))] [second (views:make (fresh-name "2"))]
            [third (views:make (fresh-name "3"))] [fourth (views:make (fresh-name "4"))])
        (layout-test/parts:set-parts!
          (layout-split:container '((direction . column))
            (layout:level '()
              (layout-split:container '((direction . row))
                (atom first) (atom second) (layout:level '() (atom third)) (atom fourth '(locked . #t))))
            (atom echo '(depth . 90) '(size . content) '(locked . #t))))
        (layout:select! second)
        (commands:run layout:reset-layout)
        (check-equal? (list second third fourth echo) (layout:views))
        (check (eq? second (layout:selected-view)))
        (let ([before (layout-test/parts:tree)])
          (commands:run layout:reset-layout)
          (check-equal? before (layout-test/parts:tree))
          (check (eq? second (layout:selected-view))))))))

(test "the display procedures take buffers"
  (check-raises (layout-test/parts:raised-with 'layout:use-other-view "not a buffer") (layout:use-other-view "mail"))
  (check-raises (layout-test/parts:raised-with 'layout:reuse-view "not a buffer") (layout:reuse-view "mail"))
  (check-raises (layout-test/parts:raised-with 'layout:find-view "not a buffer") (layout:find-view "mail"))
  (check-raises (layout-test/parts:raised-with 'layout:switch-to-buffer "not a buffer") (layout:switch-to-buffer "mail")))

(test "display-in-other-view never shows in the selected view, display-in-selected-view declines in a locked view"
  (let-values ([(a b) (apply values (start! "a" "b"))])
    (options:set! layout:display-action layout:use-other-view)
    (check (eq? b (layout:display-in-other-view (views:buffer a))))
    (check (eq? a (layout:display-in-selected-view (fresh-name "here"))))
    (let ([echo (layout-test/parts:place-echo! (fresh-name "*Echo*"))])
      (layout:select! echo)
      (check-equal? #f (layout:display-in-selected-view (fresh-name "there"))))
    (options:set! layout:display-action layout-split:display-right)))

(define calls '())

(define (note view left point) (set! calls (cons (list view (buffers:name left) point) calls)))

(hooks:add! layout:after-switch-to-buffer note)

(define (take-calls!) (let ([c (reverse calls)]) (set! calls '()) c))

(test "after-switch-to-buffer is called once for each switch to another buffer, with the view, the buffer it left and its point there"
  (let* ([v (car (start! "first"))] [first (views:buffer v)] [notes (fresh-name "notes")] [mail (fresh-name "mail")])
    (buffers:replace! notes 1 1 "one\ntwo\n")
    (take-calls!)
    (layout:switch-to-buffer notes)
    (views:set-point! v 5)
    (layout:switch-to-buffer mail)
    (check-equal? (list (list v (buffers:name first) 1) (list v (buffers:name notes) 5)) (take-calls!))
    (layout:switch-to-buffer mail)
    (views:set-buffer! v notes)
    (check-equal? '() (take-calls!))))

(test "from a locked view the hook reports the view the buffer went to; an overriding action's display elsewhere and C-x <left> call nothing"
  (let* ([v (car (start! "first"))] [notes (fresh-name "notes")])
    (layout:switch-to-buffer notes)
    (options:set! layout:display-action layout:use-other-view)
    (let ([echo (layout-test/parts:place-echo! (fresh-name "*Echo*"))])
      (layout:select! echo)
      (take-calls!)
      (layout:switch-to-buffer (fresh-name "draft"))
      (check (eq? v (layout:selected-view)))
      (check-equal? (list (list v (buffers:name notes) 1)) (take-calls!))
      (let ([w (layout-split:split-view! v (layout-split:direction row))] [other (fresh-name "other")])
        (layout:call-with-overriding-action layout:display-in-other-view
          (lambda () (layout:switch-to-buffer other)))
        (check (eq? w (layout:selected-view)))
        (check-equal? (buffers:name other) (name-of w))
        (check-equal? '() (take-calls!))
        (layout:call-with-overriding-action layout:display-in-selected-view
          (lambda () (layout:switch-to-buffer notes)))
        (check-equal? (list (list w (buffers:name other) 1)) (take-calls!))
        (commands:run layout:previous-buffer)
        (check-equal? '() (take-calls!))))
    (options:set! layout:display-action layout-split:display-right)))

(commands:define-command (display-pager) "Displays *Pager*." (layout:display-buffer (or (buffers:find "*Pager*") (buffers:make "*Pager*" ""))))

(keys:bind! keys:global "C-c p" display-pager)

(test "C-x 4 1 sends the next command's display to the selected view, and C-x 4 4 to another view"
  (let-values ([(a b) (apply values (start! "a" "b"))])
    (options:set! layout:display-action layout:use-other-view)
    (test-user:press! "C-x 4 1 C-c p")
    (check-equal? "*Pager*" (name-of a))
    (views:set-buffer! a (fresh-name "back"))
    (test-user:press! "C-x 4 4 C-c p")
    (check-equal? "*Pager*" (name-of b))
    (options:set! layout:display-action layout-split:display-right)))

(test "call-with-display-view gives the selected view when no display is overridden"
  (let ([a (car (start! "a" "b"))])
    (layout:call-with-display-view
      (lambda (view)
        (check (eq? a (view (fresh-name "mail"))))
        (check-equal? 2 (length (layout:views)))))))

(test "under an overriding action, call-with-display-view finds a view at the first ask, changes what no view shows, and the display goes there"
  (options:set! layout:display-action layout:use-other-view)
  (let-values ([(a b) (apply values (start! "a" "b"))])
    (let ([mail (fresh-name "mail")] [b-buffer (views:buffer b)])
      (layout:call-with-overriding-action layout:display-in-other-view
        (lambda ()
          (layout:call-with-display-view
            (lambda (view)
              (check (eq? b (view mail)))
              (check (eq? b (view (fresh-name "other"))))
              (views:preview-buffer! b mail)
              (views:end-preview! b)
              (check (eq? b-buffer (views:buffer b)))))
          (layout:switch-to-buffer mail)))
      (check (eq? mail (views:buffer b)))
      (check (eq? b (layout:selected-view)))
      (check (memq b-buffer (views:previous-buffers b)))
      (check (not (memq mail (views:previous-buffers b))))))
  (options:set! layout:display-action layout-split:display-right))

(test "a view call-with-display-view made is deleted when its procedure raises, and is not made when the procedure never asks"
  (let ([a (car (start! "a"))])
    (layout:call-with-overriding-action layout:display-in-other-view
      (lambda ()
        (check-raises (lambda (c) (eq? c 'quit))
          (layout:call-with-display-view
            (lambda (view)
              (let ([made (view (fresh-name "mail"))])
                (check (not (eq? made a)))
                (check-equal? 2 (length (layout:views)))
                (raise 'quit)))))
        (check-equal? 1 (length (layout:views)))
        (layout:call-with-display-view (lambda (view) #f))
        (check-equal? 1 (length (layout:views)))))))

(test "call-with-display-view takes a procedure, and its view procedure a buffer"
  (check-raises (layout-test/parts:raised-with 'layout:call-with-display-view "not a procedure") (layout:call-with-display-view 5))
  (layout:call-with-display-view
    (lambda (view)
      (check-raises (layout-test/parts:raised-with 'layout:call-with-display-view "not a buffer") (view "mail")))))

(test "the view an overriding action finds for a read begins with the buffer of the view the read started from, not the buffer asked for"
  (let ([a (car (start! "a"))] [mail (fresh-name "mail")])
    (layout:call-with-overriding-action layout:display-in-other-view
      (lambda ()
        (check-raises (lambda (c) (eq? c 'quit))
          (layout:call-with-display-view
            (lambda (view)
              (let ([made (view mail)])
                (check (eq? (views:buffer a) (views:buffer made)))
                (raise 'quit)))))))
    (check-equal? 1 (length (layout:views)))))

(test "finding the view leaves a preview another read shows in a view as it is"
  (let-values ([(a b) (apply values (start! "a" "b"))])
    (let ([outer (fresh-name "outer")] [b-buffer (views:buffer b)])
      (views:preview-buffer! b outer)
      (layout:call-with-overriding-action layout:display-in-other-view
        (lambda ()
          (layout:call-with-display-view
            (lambda (view)
              (view (fresh-name "mail"))
              (check-equal? (list #t outer) (list (views:previewing? b) (views:buffer b)))))))
      (views:end-preview! b)
      (check (eq? b-buffer (views:buffer b))))))
