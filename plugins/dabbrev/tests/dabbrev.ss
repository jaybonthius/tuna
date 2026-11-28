(import (tuna) (test) (test-user) (test-runner) (options) (ask) (hooks) (commands) (modes) (syntax) (jobs) (layout)
        (views) (buffers) (document) (completion) (completion-popup) (chez-scheme) (editing) (undo) (dabbrev))

(define said '())

;; ask's own writer reports each message as a warning, which would fail
;; the file.
(options:set! ask:message-writer (lambda (text) (set! said (cons text said))))

(define (take-said!) (let ([s (reverse said)]) (set! said '()) s))

(define ended 0)

(hooks:add! commands:after-command (lambda (command) (set! ended (+ ended 1))))

(define (view) (layout:selected-view))

(define (show! b)
  (test-user:press! "C-g")
  (views:set-buffer! (view) b)
  (views:set-point! (view) (- (document:length (buffers:document b)) 1))
  b)

(define (text b) (document:text (buffers:document b)))

(define (word-before-point)
  (let ([b (views:buffer (view))] [p (views:point (view))])
    (let-values ([(start end) (syntax:symbol-bounds b p)])
      (and start (document:text (buffers:document b) start p)))))

(define (reports-during thunk)
  (map (lambda (c) (list (condition-who c) (condition-message c))) (test-runner:reports-during thunk)))

;; M-/ pauses until its job has read words, so its key returns before it
;; ends.
(define (expand!)
  (let ([before ended])
    (test-user:press! "M-/")
    (test-runner:wait-until (lambda () (> ended before)))))

(define (expansions n)
  (let loop ([n n] [acc '()])
    (if (= n 0)
        (reverse acc)
        (begin (expand!) (loop (- n 1) (cons (word-before-point) acc))))))

(define (expand-reports) (reports-during expand!))

(define (session) (views:with-view (view) (completion:current-session)))

(define (texts s)
  (let ([ms (completion:session-matches s)])
    (map (lambda (k) (completion:text s (completion:matches-ref ms k))) (iota (completion:matches-count ms)))))

;; The sources' first answer ends a session that found nothing, so a
;; session still busy at the key may have ended once it settles.
(define (settled-texts)
  (let ([s (session)])
    (and s
         (begin
           (test-runner:wait-until (lambda () (or (not (eq? s (session))) (not (completion:session-busy? s)))))
           (and (eq? s (session)) (texts s))))))

(define (with-setting option value thunk)
  (options:set! option value)
  (thunk)
  (options:unset! option))

(test "M-/ replaces the abbreviation with the nearest expansion before point, then after it, then in friend buffers, then in the others; with none left, it puts the abbreviation back"
  (let ([here (buffers:make "here" "apricot apple ap application")])
    (buffers:make "friend" "apex")
    (modes:set-major-mode chez-scheme:mode (buffers:make "s.ss" "apology"))
    (buffers:make " internal" "apiary")
    (show! here)
    (views:set-point! (view) (+ 1 (string-length "apricot apple ap")))
    (take-said!)
    (check-equal? '("apple" "apricot" "application") (expansions 3))
    (check-equal? '() (take-said!))
    (check-equal? '("apex") (expansions 1))
    (check-equal? '("Expansion found in ‘friend’") (take-said!))
    (check-equal? '("apology") (expansions 1))
    (check-equal? '("Expansion found in ‘s.ss’") (take-said!))
    (check-equal? '((dabbrev:expand "No further dynamic expansion for ‘ap’ found")) (expand-reports))
    (check-equal? "apricot apple ap application" (text here))
    (check-equal? '("apple") (expansions 1))))

(test "each M-/ that puts a word from another buffer names that buffer, though the last named it too"
  (show! (buffers:make "naming" "qx"))
  (buffers:make "named" "qxone qxtwo")
  (take-said!)
  (check-equal? '("qxone") (expansions 1))
  (check-equal? '("Expansion found in ‘named’") (take-said!))
  (check-equal? '("qxtwo") (expansions 1))
  (check-equal? '("Expansion found in ‘named’") (take-said!))
  (test-user:press! "C-g"))

(test "only the buffers friend-buffer-predicate accepts are friends, searched before the others"
  (let ([near (buffers:make "near" "jknear")] [far (buffers:make "far" "jkfar")])
    (show! (buffers:make "befriending" "jk"))
    (with-setting dabbrev:friend-buffer-predicate (lambda (b) (eq? b far))
      (lambda ()
        (with-setting dabbrev:check-all-buffers #f
          (lambda ()
            (check-equal? '("jkfar") (expansions 1))
            (check-equal? '((dabbrev:expand "No further dynamic expansion for ‘jk’ found")) (expand-reports))))))
    (buffers:kill! near)
    (buffers:kill! far))
  (take-said!))

(test "a buffer ignored-buffer-predicate accepts is never searched"
  (let ([kept (buffers:make "kept" "vwkept")] [ignored (buffers:make "ignored" "vwignored")])
    (show! (buffers:make "ignoring" "vw"))
    (with-setting dabbrev:ignored-buffer-predicate (lambda (b) (eq? b ignored))
      (lambda ()
        (check-equal? '("vwkept") (expansions 1))
        (check-equal? '((dabbrev:expand "No further dynamic expansion for ‘vw’ found")) (expand-reports))))
    (buffers:kill! kept)
    (buffers:kill! ignored))
  (take-said!))

(test "after another command, M-/ starts afresh from the text before point"
  (let ([here (show! (buffers:make "afresh" "apricot apple ap"))])
    (expand!)
    (test-user:press! "C-b C-f")
    (check-equal? '((dabbrev:expand "No dynamic expansion for ‘apple’ found")) (expand-reports))
    (test-user:press! "DEL DEL DEL")
    (expand!)
    (check-equal? "apricot apple apple" (text here))))

(test "other buffers only with check-other-buffers, and all the rest only with check-all-buffers"
  (show! (buffers:make "here 2" "apricot apple ap"))
  (with-setting dabbrev:check-all-buffers #f
    (lambda ()
      (check-equal? '("apple" "apricot" "application" "apex") (expansions 4))
      (check-equal? '((dabbrev:expand "No further dynamic expansion for ‘ap’ found")) (expand-reports))
      (with-setting dabbrev:check-other-buffers #f
        (lambda ()
          (test-user:press! "C-g")
          (check-equal? '("apple" "apricot") (expansions 2))
          (check-equal? '((dabbrev:expand "No further dynamic expansion for ‘ap’ found")) (expand-reports))))))
  (take-said!))

(define (cased typed)
  (show! (buffers:make (buffers:free-name (string-append "cased " typed)) (string-append "Apple apTitude\n" typed))))

(test "the expansion takes the case of the text it replaces, unless its own case is mixed past its first letter and it starts as typed"
  (with-setting dabbrev:check-other-buffers #f
    (lambda ()
      (cased "AP")
      (check-equal? '("APTITUDE" "APPLE") (expansions 2))
      (cased "Ap")
      (check-equal? '("Aptitude" "Apple") (expansions 2))
      (cased "ap")
      (check-equal? '("apTitude" "apple") (expansions 2)))))

(test "with case-fold-search off only words in the typed case are found; with case-replace off an expansion keeps its own case"
  (with-setting dabbrev:check-other-buffers #f
    (lambda ()
      (with-setting dabbrev:case-fold-search #f
        (lambda ()
          (cased "ap")
          (check-equal? '("apTitude") (expansions 1))
          (check-equal? '((dabbrev:expand "No further dynamic expansion for ‘ap’ found")) (expand-reports))))
      (with-setting dabbrev:case-replace #f
        (lambda ()
          (cased "AP")
          (check-equal? '("apTitude" "Apple") (expansions 2)))))))

(test "in a Scheme buffer the abbreviation is a Scheme symbol, colon and all; with no symbol before point there is none"
  (let ([code (buffers:make "code.ss" "(buffers:insert! b)\n(buffers:ins")])
    (modes:set-major-mode chez-scheme:mode code)
    (show! code)
    (views:set-point! (view) (document:length (buffers:document code)))
    (check-equal? '("buffers:insert!") (expansions 1))
    (test-user:type! " ")
    (check-equal? '((dabbrev:expand "No possible abbreviation preceding point")) (expand-reports))))

(test "C-M-/ completes from this buffer's words, and with C-u from the friend buffers' too, in the abbreviation's case"
  (with-setting dabbrev:check-other-buffers #f
    (lambda ()
      (show! (buffers:make "words" "alpha almond\n"))
      (buffers:make "more" "alpine")
      (test-user:type! "al")
      (test-user:press! "C-M-/")
      (check-equal? '("alpha" "almond") (settled-texts))
      (test-user:press! "C-g C-u C-M-/")
      (check-equal? '("alpha" "almond" "alpine") (settled-texts))
      (test-user:press! "C-g SPC")
      (check-equal? '((dabbrev:completion "No possible abbreviation preceding point"))
        (reports-during (lambda () (test-user:press! "C-M-/"))))
      (test-user:type! "AL")
      (test-user:press! "C-M-/")
      (check-equal? '("ALPHA" "ALMOND") (settled-texts))
      (test-user:press! "C-g SPC")
      (test-user:type! "Al")
      (test-user:press! "C-M-/")
      (check-equal? '("Alpha" "Almond") (settled-texts))
      (test-user:press! "C-g"))))

(test "with no expansion C-M-/ says so once its job has looked, naming this buffer unless it read others"
  (show! (buffers:make "none" "alpha\n"))
  (take-said!)
  (test-user:type! "qq")
  (test-user:press! "C-M-/")
  (test-runner:wait-until (lambda () (pair? said)))
  (check-equal? '(#f ("No dynamic expansion for ‘qq’ found in this-buffer")) (list (session) (take-said!)))
  (test-user:press! "C-u C-M-/")
  (test-runner:wait-until (lambda () (pair? said)))
  (check-equal? '("No dynamic expansion for ‘qq’ found") (take-said!)))

(test "a prefix of 16, as C-u C-u gives, reads every buffer not ignored"
  (with-setting dabbrev:check-other-buffers #f
    (lambda ()
      (show! (buffers:make "asking far" "x\n"))
      (modes:set-major-mode chez-scheme:mode (buffers:make "faraway" "alfalfa"))
      (test-user:type! "alf")
      (take-said!)
      (test-user:press! "C-u C-M-/")
      (check-equal? #f (settled-texts))
      (test-runner:wait-until (lambda () (pair? said)))
      (check-equal? '("No dynamic expansion for ‘alf’ found") (take-said!))
      (test-user:press! "C-g C-u 1 6 C-M-/")
      (check-equal? '("alfalfa") (settled-texts))
      (test-user:press! "C-g"))))

(define (zeds)
  (let* ([v (views:current)] [p (views:point v)])
    (completion:region (- p 2) p (list (completion:source (candidates (vector "zeta" "zero")))))))

(test "word-region is an entry a configuration adds, which gives way to the next entry when no word matches, and offers the words of the buffers region-buffer-predicate accepts"
  (with-setting dabbrev:check-other-buffers #f
    (lambda ()
      (let ([more (buffers:make "more words" "alpine")])
        (show! (buffers:make "regions" "alpha almond\n"))
        (hooks:add! completion:find-region dabbrev:word-region -2)
        (hooks:add! completion:find-region zeds -1)
        (test-user:type! "alm")
        (test-user:press! "C-M-i")
        (check-equal? '("almond") (settled-texts))
        (test-user:press! "C-g SPC")
        (test-user:type! "ze")
        (test-user:press! "C-M-i")
        (test-runner:wait-until (lambda () (let ([s (session)]) (and s (pair? (texts s))))))
        (check-equal? '("zero" "zeta") (texts (session)))
        (test-user:press! "C-g")
        (with-setting dabbrev:region-buffer-predicate (lambda (b) (eq? b more))
          (lambda ()
            (test-user:press! "SPC")
            (test-user:type! "alpi")
            (test-user:press! "C-M-i")
            (check-equal? '("alpine") (settled-texts))
            (test-user:press! "C-g")))
        (hooks:remove! completion:find-region zeds)
        (hooks:remove! completion:find-region dabbrev:word-region)))))

(define (colon-symbols symbol-characters buffer)
  (if (string=? (buffers:name buffer) "colons")
      (string-append (symbol-characters buffer) ":")
      (symbol-characters buffer)))

(test "a minor mode that changes a buffer's characters through syntax:buffer-symbol-characters changes the abbreviation and the words read there"
  (show! (buffers:make "colons" "pi:menu pi:chat\npi:m"))
  (check-equal? '("menu") (expansions 1))
  (test-user:press! "C-/ C-g")
  (advice-add! syntax:buffer-symbol-characters colon-symbols)
  (check-equal? '("pi:menu") (expansions 1))
  (advice-remove! syntax:buffer-symbol-characters colon-symbols)
  (take-said!))

(test "with backward-only, M-/ looks only before point; with upcase-means-case-search, a capital in the abbreviation keeps case"
  (with-setting dabbrev:check-other-buffers #f
    (lambda ()
      (show! (buffers:make "directions" "Before before  after"))
      (views:set-point! (view) (+ 1 (string-length "Before before ")))
      (test-user:type! "b")
      (check-equal? '("before") (expansions 1))
      (check-equal? '((dabbrev:expand "No further dynamic expansion for ‘b’ found")) (expand-reports))
      (test-user:press! "DEL")
      (test-user:type! "a")
      (check-equal? '("after") (expansions 1))
      (test-user:press! "C-/ C-g")
      (with-setting dabbrev:backward-only #t
        (lambda ()
          (check-equal? '((dabbrev:expand "No dynamic expansion for ‘a’ found")) (expand-reports))))
      (test-user:press! "DEL")
      (test-user:type! "B")
      (check-equal? '("BEFORE") (expansions 1))
      (check-equal? '((dabbrev:expand "No further dynamic expansion for ‘B’ found")) (expand-reports))
      (with-setting dabbrev:upcase-means-case-search #t
        (lambda ()
          (test-user:press! "C-g")
          (check-equal? '("Before") (expansions 1))
          (check-equal? '((dabbrev:expand "No further dynamic expansion for ‘B’ found")) (expand-reports))))))
  (take-said!))

(test "an expansion that arrives after keys typed while M-/ waited is dropped, so it never lands in what was typed"
  (let ([waiting (show! (buffers:make "waiting" "zyz"))])
    (buffers:make "far" (string-append (apply string-append (make-list 2000000 "zz ")) "zyzzyva"))
    (let ([before ended])
      (test-user:press! "M-/ x")
      (test-runner:wait-until (lambda () (> ended (+ before 1)))))
    (check-equal? '("zyzx" 5) (list (text waiting) (views:point (view))))
    (test-user:press! "DEL")
    (expand!)
    (check-equal? "zyzzyva" (word-before-point)))
  (take-said!))

(test "each M-/ offers the next nearest expansion across the job's chunks, which asks for more only once all it sent are offered"
  (with-setting dabbrev:check-other-buffers #f
    (lambda ()
      (show! (buffers:make "many" (apply string-append (append (map (lambda (k) (format "w~a " k)) (iota 2001)) '("w")))))
      (let* ([asked 0] [count-asks (lambda (send! job v) (when (eq? v 'more) (set! asked (+ asked 1))) (send! job v))])
        (advice-add! jobs:send! count-asks)
        (check-equal? '("w2000" "w1999") (expansions 2))
        (check-equal? 0 asked)
        (expansions 1198)
        (check-equal? '("w801" #t) (list (word-before-point) (< 0 asked 6)))
        (advice-remove! jobs:send! count-asks)))))

(test "while case is ignored, words that differ only in case count as one, unless case-distinction is false"
  (with-setting dabbrev:check-other-buffers #f
    (lambda ()
      (show! (buffers:make "cases" "Apple apple ap"))
      (check-equal? '("apple") (expansions 1))
      (check-equal? '((dabbrev:expand "No further dynamic expansion for ‘ap’ found")) (expand-reports))
      (with-setting dabbrev:case-distinction #f
        (lambda ()
          (test-user:press! "C-g")
          (check-equal? '("apple" "apple") (expansions 2)))))))

(test "an expansion's job holds the documents of the buffers it searches until a command other than M-/ ends"
  (let* ([held (buffers:make "held" "zebra zebrafish")]
         [held-document (weak-cons (buffers:document held) '())]
         [released? (lambda () (collect (collect-maximum-generation)) (bwp-object? (car held-document)))])
    (show! (buffers:make "pressing" "zeb"))
    (check-equal? '("zebra") (expansions 1))
    (buffers:kill! held)
    (set! held #f)
    (check-equal? #f (released?))
    (check-equal? '("zebrafish") (expansions 1))
    (check-equal? #f (released?))
    (test-user:press! "C-b")
    (test-runner:wait-until released?))
  (take-said!))

(test "other buffers are searched in the order of use, the buffer used last first"
  (let ([older (buffers:make "older" "quokka")] [newer (buffers:make "newer" "quarry")] [asking (buffers:make "asking" "qu")])
    (layout:switch-to-buffer older)
    (layout:switch-to-buffer asking)
    (views:set-point! (view) 3)
    (check-equal? '("quokka") (expansions 1))
    (test-user:press! "C-g DEL DEL DEL DEL DEL DEL q u")
    (layout:switch-to-buffer newer)
    (layout:switch-to-buffer asking)
    (views:set-point! (view) 3)
    (check-equal? '("quarry") (expansions 1)))
  (take-said!))
