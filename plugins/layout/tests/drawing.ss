(import (tuna) (test))

;; A form of its own, so it loads before layout.
(import (layout-test beneath))

(import (test-user) (layout) (layout-split) (views) (buffers) (web) (haml) (options) (timers) (tables)
        (layout-test parts) (layout-test quits))

(define reports-during layout-test/parts:reports-during)

;; Chez's own errors carry a format string, others a plain message.
(define (describe c)
  (cond
    [(not (message-condition? c)) c]
    [(memv #\~ (string->list (condition-message c)))
     (apply format #f (condition-message c) (if (irritants-condition? c) (condition-irritants c) '()))]
    [else (condition-message c)]))

(define (messages reports) (map describe reports))

(define (error-text client)
  (let ([e (test-user:elements (test-user:screen client) "layout-error")])
    (and (pair? e) (test-user:element-text (car e)))))

(define (with-screen-advice advice thunk)
  (advice-add! layout:screen advice)
  (let ([result (thunk)])
    (advice-remove! layout:screen advice)
    result))

(define desktop (test-user:open-client))
(define phone (test-user:open-client))

(define (draws-during thunk)
  (let ([drawn '()])
    (with-screen-advice (lambda (screen client) (set! drawn (cons (cons (layout-test/beneath:batch) client) drawn)) (screen client)) thunk)
    (reverse drawn)))

(test "after each batch layout draws every client of web:clients, in order, whether or not anything changed, after the advice beneath its own"
  (let* ([first (layout-test/beneath:batch)] [drawn (draws-during (lambda () (test-user:settle) (test-user:settle)))]
         [batches (let loop ([b (+ first 1)]) (if (> b (layout-test/beneath:batch)) '() (cons b (loop (+ b 1)))))])
    (check (>= (length batches) 2))
    (check-equal? (apply append (map (lambda (b) (map (lambda (c) (cons b c)) (web:clients))) batches)) drawn)))

(test "advice on drawing runs as its owner"
  (let ([owners '()] [mine (current-owner)])
    (with-screen-advice (lambda (screen client) (set! owners (cons (current-owner) owners)) (screen client)) test-user:settle)
    (check (pair? owners))
    (check (for-all (lambda (o) (eq? o mine)) owners))))

(test "a draw that raises is reported once until a draw for that client succeeds, the client shows the condition, and the others are drawn"
  (let* ([fails (lambda (screen client) (if (eq? client desktop) (car '()) (screen client)))]
         [reported (reports-during
                     (lambda ()
                       (with-screen-advice fails (lambda () (test-user:settle) (test-user:settle)))))])
    (check-equal? '(car) (map condition-who reported))
    (check-equal? '("() is not a pair") (messages reported))
    (check-equal? "Exception in car: () is not a pair" (error-text desktop))
    (check-equal? (string-append (layout-test/parts:selected-name) " - Tuna") (test-user:title desktop))
    (check-equal? #f (error-text phone))
    (test-user:settle)
    (check-equal? #f (error-text desktop))
    (check-equal? 1 (length (reports-during (lambda () (with-screen-advice fails test-user:settle)))))
    (test-user:settle)))

(test "a raise of what is no condition is shown and reported for each client it fails"
  (let ([reported (reports-during (lambda () (with-screen-advice (lambda (screen client) (raise 'oops)) test-user:settle)))])
    (check-equal? (map (lambda (c) 'oops) (web:clients)) reported)
    (check-equal? "Exception occurred with non-condition value oops" (error-text desktop)))
  (test-user:settle))

(test "a warning while drawing is reported, and the draw goes on"
  (let* ([warn? #t]
         [warns (lambda (screen client)
                  (when warn? (set! warn? #f) (warning 'draw "careful"))
                  (screen client))]
         [reported (reports-during (lambda () (with-screen-advice warns test-user:settle)))])
    (check-equal? '("careful") (messages reported))
    (check (warning? (car reported)))
    (check-equal? #f (error-text desktop))
    (check-equal? 1 (length (test-user:elements (test-user:screen desktop) "layout-screen")))))

(test "a quit ends the draw it lands in, unreported; the other clients are drawn, and the next batch draws again"
  (let* ([quit? #t] [events '()]
         [quit-on-desktop
           (lambda (screen client)
             (when (and quit? (eq? client desktop))
               (set! quit? #f)
               (set! events (cons 'quit events))
               (layout-test/quits:request-quit!)
               (let spin () (spin)))
             (let ([s (screen client)]) (set! events (cons client events)) s))]
         [reported (reports-during
                     (lambda () (with-screen-advice quit-on-desktop (lambda () (test-user:settle) (test-user:settle)))))]
         [after (cdr (memq 'quit (reverse events)))])
    (check-equal? '() reported)
    (check (eq? phone (find (lambda (c) (memq c (list desktop phone))) after)))
    (check (memq desktop after))))

(test "a command that runs a long time shows its progress by ending the batch"
  (let* ([progress 0] [drawn '()]
         [note (lambda (screen client) (when (eq? client desktop) (set! drawn (cons progress drawn))) (screen client))])
    (with-screen-advice note
      (lambda ()
        (test-user:settle)
        (set! drawn '())
        (for-each (lambda (i) (set! progress i) (timers:sleep 0)) '(1 2 3))))
    (check-equal? '(1 2 3) (reverse drawn))))

(test "a raise or a quit in the advice beneath layout's is reported, and the clients are still drawn"
  (for-each
    (lambda (set-flag! reported?)
      (let ([drawn 0])
        (let ([reported (reports-during
                          (lambda ()
                            (with-screen-advice (lambda (screen client) (set! drawn (+ drawn 1)) (screen client))
                              (lambda () (set-flag!) (test-user:settle)))))])
          (check-equal? 1 (length reported))
          (check (reported? (car reported)))
          (check (>= drawn (length (web:clients)))))))
    (list layout-test/beneath:fail-next! layout-test/beneath:cancel-next!)
    (list (lambda (c) (equal? "() is not a pair" (describe c))) cancelled?)))

(test "every page is titled with the selected view's buffer's name, after a switch, a selection or a rename"
  (let* ([notes (buffers:make (buffers:free-name "notes") "one\n")] [mail (buffers:make (buffers:free-name "mail") "Dear Harpo,\n")])
    (layout:switch-to-buffer notes)
    (test-user:settle)
    (check-equal? (string-append (buffers:name notes) " - Tuna") (test-user:title desktop))
    (let ([v (layout:display-buffer mail)])
      (test-user:settle)
      (check-equal? (string-append (buffers:name notes) " - Tuna") (test-user:title desktop))
      (layout:select! v)
      (test-user:settle)
      (check-equal? (map (lambda (c) (string-append (buffers:name mail) " - Tuna")) (web:clients)) (map test-user:title (web:clients)))
      (buffers:rename! mail (buffers:free-name "sent"))
      (test-user:settle)
      (check-equal? (string-append (buffers:name mail) " - Tuna") (test-user:title phone)))))

(test "layout:page-title makes the title from the buffer's name"
  (options:set! layout:page-title (lambda (name) (string-append name " – Tuna")))
  (test-user:settle)
  (check-equal? (string-append (layout-test/parts:selected-name) " – Tuna") (test-user:title desktop))
  (options:unset! layout:page-title)
  (test-user:settle)
  (check-equal? (string-append (layout-test/parts:selected-name) " - Tuna") (test-user:title desktop)))

(test "a page title that raises or makes no string is reported once, and every page is titled Tuna and still drawn"
  (for-each
    (lambda (title expected)
      (let ([reported (reports-during
                        (lambda ()
                          (options:set! layout:page-title title)
                          (test-user:settle)
                          (test-user:settle)))])
        (check-equal? (list expected) (messages reported))
        (check-equal? (map (lambda (c) "Tuna") (web:clients)) (map test-user:title (web:clients)))
        (check-equal? 1 (length (test-user:elements (test-user:screen desktop) "layout-screen"))))
      (options:unset! layout:page-title)
      (test-user:settle)
      (check-equal? (string-append (layout-test/parts:selected-name) " - Tuna") (test-user:title desktop)))
    (list (lambda (name) (car '())) (lambda (name) 42))
    '("() is not a pair" "returned what is not a string")))

(test "advice on draw-view-atom draws around a view, as the page's header example does"
  (let ([with-header (lambda (draw node view client)
                       (list (haml (:header.test-header (buffers:name (views:buffer view)))) (draw node view client)))])
    (advice-add! layout:draw-view-atom with-header)
    (test-user:settle)
    (advice-remove! layout:draw-view-atom with-header)
    (let ([headers (test-user:elements (test-user:screen desktop) "test-header")])
      (check-equal? (map layout-test/parts:name-of (layout:views)) (map test-user:element-text headers)))))

(test "with no client, nothing is drawn"
  (for-each web:close-client! (web:clients))
  (let ([draws 0])
    (with-screen-advice (lambda (screen client) (set! draws (+ draws 1)) (screen client)) test-user:settle)
    (check-equal? 0 draws)))

(test "layout's stylesheet is in web's table of stylesheets"
  (check-equal? "layout/layout.css" (tables:ref web:stylesheets 'layout #f)))
