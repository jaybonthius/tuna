(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (timers) (commands) (keys) (buffers) (document) (views)
        (layout) (layout-split) (editing) (files) (modes) (echo-area) (pulse) (jump-history) (diagnostics) (diagnostics-list) (diagnostics-list-test lists))

(options:set! diagnostics:check-delay #f)

(keys:bind! keys:global "C-c l b" diagnostics-list:show-buffer-diagnostics)

(define (reports-during thunk)
  (map (lambda (c) (list (condition-who c) (condition-message c))) (test-runner:reports-during thunk)))

(define (places) (map (lambda (p) (cons (buffers:name (car p)) (cdr p))) (jump-history:places)))

(mkdir diagnostics-list-test/lists:root)
(mkdir (string-append diagnostics-list-test/lists:root "/.git"))

(define notes (files:visit (diagnostics-list-test/lists:write-file! "notes.txt" "alpha beta gamma\ndelta epsilon\nzeta eta\n")))

(layout:switch-to-buffer notes)

(define nv (layout:selected-view))

(define source (diagnostics:make-source))

(define (report! . ds) (diagnostics:report! source notes ds))

(report! (diagnostics-list-test/lists:mark notes "beta" (diagnostics:severity warning) "vague")
         (diagnostics:make-diagnostic (diagnostics-list-test/lists:word notes "delta") (+ (diagnostics-list-test/lists:word notes "delta") 5) (diagnostics:severity error) "wrong"
           (diagnostics:details [origin "lint"] [code "E1"]))
         (diagnostics-list-test/lists:mark notes "zeta" (diagnostics:severity info) "short"))

(define lv #f)

(test "a buffer's list needs the mode on there"
  (check-equal? '((diagnostics-list:show-buffer-diagnostics "Diagnostics are off in this buffer"))
                (reports-during (lambda () (test-user:press! "C-c l b")))))

(test "a buffer's list shows a row per diagnostic, its line and column, its severity, origin and code, and message, with the row of the diagnostic at point selected, in a view it does not select"
  (diagnostics-list-test/lists:mode! notes #t)
  (views:set-point! nv (+ (diagnostics-list-test/lists:word notes "delta") 2))
  (test-user:press! "C-c l b")
  (set! lv (diagnostics-list-test/lists:list-view "notes.txt"))
  (check-equal? '(("1:6" "warning" "vague") ("2:0" "error" "lint E1" "wrong") ("3:0" "info" "short")) (diagnostics-list-test/lists:rows lv))
  (check-equal? '(1 #f) (list (diagnostics-list-test/lists:selected lv) (eq? (layout:selected-view) lv)))
  (check-equal? diagnostics-list:mode (modes:major-mode (views:buffer lv)))
  (check (modes:derived? diagnostics-list:mode modes:special)))

(test "the severity is drawn in error, warning or success"
  (check-equal? '("error" "warning" "success")
                (map (lambda (i)
                       (test-user:element-attribute
                         (find (lambda (e) (test-user:element-attribute e "data-face"))
                               (test-user:elements (list-ref (diagnostics-list-test/lists:row-elements lv) i) "ui-label"))
                         "data-face"))
                     '(1 0 2))))

(test "the list follows changes, keeping each view's selected diagnostic"
  (let ([delta (cadr (diagnostics:in notes))])
    (report! (diagnostics-list-test/lists:mark notes "alpha" (diagnostics:severity error) "first")
             (diagnostics-list-test/lists:mark notes "beta" (diagnostics:severity warning) "vague") delta (diagnostics-list-test/lists:mark notes "zeta" (diagnostics:severity info) "short"))
    (check-equal? '(("1:0" "1:6" "2:0" "3:0") 2) (list (map car (diagnostics-list-test/lists:rows lv)) (diagnostics-list-test/lists:selected lv)))
    (buffers:replace! notes (diagnostics-list-test/lists:word notes "alpha") (+ (diagnostics-list-test/lists:word notes "alpha") 5) "")
    (check-equal? '(("1:1" "2:0" "3:0") 1) (list (map car (diagnostics-list-test/lists:rows lv)) (diagnostics-list-test/lists:selected lv)))))

(test "the list's keys run public commands, which a user can bind elsewhere"
  (check-equal? (list (cons "RET" diagnostics-list:go-to-diagnostic) (cons "SPC" diagnostics-list:show-diagnostic)
                      (cons "C-o" diagnostics-list:show-diagnostic) (cons "n" diagnostics-list:next-diagnostic)
                      (cons "p" diagnostics-list:previous-diagnostic) (cons "<mouse-2>" editing:mouse-set-point))
                (keys:bindings diagnostics-list:keymap)))

(test "RET goes to the selected row's diagnostic in another view, selects it, records the place that view leaves, and highlights the diagnostic until the next command"
  (views:set-point! nv 1)
  (layout:select! lv)
  (test-user:press! "RET")
  (check-equal? (list #t (diagnostics-list-test/lists:word notes "delta") '(("notes.txt" . 1)) #t #f)
                (list (eq? (layout:selected-view) nv) (views:point nv) (places) (diagnostics-list-test/lists:pulsed? nv) (diagnostics-list-test/lists:pulsed? lv)))
  (test-user:press! "C-f")
  (check-equal? #f (diagnostics-list-test/lists:pulsed? nv)))

(test "SPC and C-o show the row's diagnostic there highlighted, stay in the list and record no jump; n and p move to the next and previous row and show it"
  (layout:select! lv)
  (let ([before (jump-history:places)])
    (test-user:press! "p")
    (check-equal? (list #t 0 2) (list (eq? (layout:selected-view) lv) (diagnostics-list-test/lists:selected lv) (views:point nv)))
    (test-user:press! "n n")
    (check-equal? (list #t 2 (diagnostics-list-test/lists:word notes "zeta")) (list (eq? (layout:selected-view) lv) (diagnostics-list-test/lists:selected lv) (views:point nv)))
    (views:set-point! nv 1)
    (test-user:press! "C-p SPC")
    (check-equal? (list #t (diagnostics-list-test/lists:word notes "delta") #t) (list (eq? (layout:selected-view) lv) (views:point nv) (diagnostics-list-test/lists:pulsed? nv)))
    (views:set-point! nv 1)
    (test-user:press! "C-o")
    (check-equal? (diagnostics-list-test/lists:word notes "delta") (views:point nv))
    (check-equal? before (jump-history:places))))

(test "the highlight also ends by itself, after pulse:duration"
  (options:set! pulse:duration 0.05)
  (test-user:press! "SPC")
  (test-runner:wait-until (lambda () (not (diagnostics-list-test/lists:pulsed? nv))))
  (options:unset! pulse:duration))

(test "n and p name the list they move in, as next-error does; on the last row n shows the last diagnostic again"
  (test-user:press! "n")
  (check-equal? (list 2 (diagnostics-list-test/lists:word notes "zeta") #t "Next locus from *Diagnostics notes.txt*")
                (list (diagnostics-list-test/lists:selected lv) (views:point nv) (diagnostics-list-test/lists:pulsed? nv) (echo-area:current-message)))
  (views:set-point! nv 1)
  (test-user:press! "n")
  (check-equal? (list 2 (diagnostics-list-test/lists:word notes "zeta") "Next locus from *Diagnostics notes.txt*")
                (list (diagnostics-list-test/lists:selected lv) (views:point nv) (echo-area:current-message)))
  (test-user:press! "p")
  (check-equal? '(1 "Previous locus from *Diagnostics notes.txt*") (list (diagnostics-list-test/lists:selected lv) (echo-area:current-message))))

(test "a digit is a count, as in every special buffer, and S-SPC and DEL scroll"
  (test-user:press! "M-< 2 n")
  (check-equal? 2 (diagnostics-list-test/lists:selected lv))
  (check-equal? (list views:scroll-down views:scroll-down)
                (views:call-with-view lv (lambda () (map (lambda (k) (keys:lookup (test-user:client) k)) '("S-SPC" "DEL"))))))

(test "g builds the list again, keeping the selection, and runs diagnostics-list:refresh; q quits its view"
  (test-user:press! "C-p")
  (check (eq? diagnostics-list:refresh (buffers:with-buffer (views:buffer lv) (buffers:revert-function))))
  (test-user:press! "g")
  (check-equal? '(("1:1" "2:0" "3:0") 1) (list (map car (diagnostics-list-test/lists:rows lv)) (diagnostics-list-test/lists:selected lv)))
  (test-user:press! "q")
  (check (not (memq lv (layout:views)))))

(test "RET in a list with no rows says there is nothing at point"
  (diagnostics:clear! source)
  (layout:select! nv)
  (test-user:press! "C-c l b")
  (set! lv (diagnostics-list-test/lists:list-view "notes.txt"))
  (check (eq? nv (layout:selected-view)))
  (layout:select! lv)
  (check-equal? '((diagnostics-list:go-to-diagnostic "Nothing at point")) (reports-during (lambda () (test-user:press! "RET")))))

(test "with the list alone in its level, RET splits a view for the source and selects it, keeping the list"
  (report! (diagnostics-list-test/lists:mark notes "beta" (diagnostics:severity warning) "vague") (diagnostics-list-test/lists:mark notes "zeta" (diagnostics:severity info) "short"))
  (let ([shown (lambda () (map views:buffer (filter (lambda (v) (memq (views:buffer v) (list notes (views:buffer lv)))) (layout:views))))])
    (layout:select! nv)
    (test-user:press! "C-x 0")
    (check-equal? (list #t (list (views:buffer lv))) (list (eq? lv (layout:selected-view)) (shown)))
    (test-user:press! "M-> RET")
    (check-equal? (list notes (diagnostics-list-test/lists:word notes "zeta") (list (views:buffer lv) notes))
                  (list (views:buffer (layout:selected-view)) (views:point (layout:selected-view)) (shown)))))

(test "SPC, C-o, n and p show a diagnostic without recentring the source's view; RET, a jump, recentres it"
  (let ([centred '()])
    (define (note-centre next v p align)
      (when (eq? align (views:align center)) (set! centred (cons (views:buffer v) centred)))
      (next v p align))
    (advice-add! views:scroll-to! note-centre)
    (layout:select! lv)
    (test-user:press! "M-< SPC C-o n p")
    (check-equal? '() centred)
    (test-user:press! "RET")
    (check-equal? (list notes) centred)
    (advice-remove! views:scroll-to! note-centre)))
