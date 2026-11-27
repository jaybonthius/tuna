(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (timers) (buffers) (document) (files) (views) (layout)
        (docs-at-point) (diagnostics) (diagnostics-test marks) (diagnostics-test reporter))

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

(define (syntax-error? message)
  (lambda (c) (and (syntax-violation? c) (string=? message (condition-message c)))))

(test-user:show! "|alpha beta gamma\ndelta epsilon\n\nzeta eta\n")

(define notes (views:buffer (layout:selected-view)))

(define linter (diagnostics:make-source))

(define server (diagnostics:make-source))

(define d
  (diagnostics:make-diagnostic 1 6 (diagnostics:severity warning) "\"alpha\" is not accessed"
    (diagnostics:details [origin "basedpyright"] [code "reportUnusedImport"] [tags (diagnostics:tags unnecessary)])))

(test "a diagnostic is a range, a severity, a message and its details; made, it marks no buffer yet"
  (check-equal? '(1 6 warning "\"alpha\" is not accessed" "basedpyright" "reportUnusedImport" (unnecessary) #f #f #f #f)
                (list (diagnostics:diagnostic-start d) (diagnostics:diagnostic-end d) (diagnostics:diagnostic-severity d)
                      (diagnostics:diagnostic-message d) (diagnostics:diagnostic-origin d) (diagnostics:diagnostic-code d)
                      (enum-set->list (diagnostics:diagnostic-tags d)) (diagnostics:diagnostic-keymap d)
                      (diagnostics:diagnostic-data d) (diagnostics:diagnostic-buffer d) (diagnostics:diagnostic-path d)))
  (check (diagnostics:diagnostic? d))
  (check-equal? '(data) (diagnostics:diagnostic-data (diagnostics:make-diagnostic 1 2 (diagnostics:severity hint) "x"
                                                       (diagnostics:details [data '(data)]))))
  (check-equal? '() (enum-set->list (diagnostics:diagnostic-tags (diagnostics:make-diagnostic 1 2 (diagnostics:severity hint) "x")))))

(test "diagnostics:text writes the origin, the code in brackets, a colon and the message"
  (check-equal? "basedpyright [reportUnusedImport]: \"alpha\" is not accessed" (diagnostics:text d))
  (check-equal? "plain" (diagnostics:text (diagnostics:make-diagnostic 1 2 (diagnostics:severity info) "plain"))))

(test "a diagnostic's arguments are checked"
  (check-raises (raised? 'diagnostics:make-diagnostic "not a severity") (diagnostics:make-diagnostic 1 2 'fatal "x"))
  (check-raises (raised? 'diagnostics:make-diagnostic "not a string") (diagnostics:make-diagnostic 1 2 (diagnostics:severity info) 'x))
  (check-raises (raised? 'diagnostics:make-diagnostic "not an end position after the start")
                (diagnostics:make-diagnostic 5 2 (diagnostics:severity info) "x"))
  (check-raises (raised? 'diagnostics:make-diagnostic "not an end position after the start")
                (diagnostics:make-diagnostic 5 #f (diagnostics:severity info) "x")))

(test "an unknown severity, tag or clause, or a clause given twice, is a syntax error"
  (for-each
    (lambda (module message) (check-raises (syntax-error? message) (load-module! (list 'diagnostics-test 'bad-forms module))))
    '(severity tag clause-twice unknown-clause)
    '("not a severity" "not a tag" "clause given twice" "invalid clause")))

(test "where the mode is on, a report draws each diagnostic as a span of its severity's layer type, in its severity's face with its text as title"
  (diagnostics-test/marks:mode! notes #t)
  (check (diagnostics:report! linter notes (list (diagnostics-test/marks:warn notes "beta" "vague") (diagnostics-test/marks:err notes "delta" "wrong"))))
  (check-equal? '(("delta" (diagnostic.error) "wrong") ("beta" (diagnostic.warning) "vague")) (diagnostics-test/marks:marks notes))
  (diagnostics:report! linter notes (list d))
  (check-equal? '(("alpha" (diagnostic.warning diagnostic.unnecessary) "basedpyright [reportUnusedImport]: \"alpha\" is not accessed"))
                (diagnostics-test/marks:marks notes))
  (check-equal? (list notes linter) (list (diagnostics:diagnostic-buffer d) (diagnostics:diagnostic-source d))))

(test "a source's report replaces its earlier one there, and another source's stay"
  (diagnostics:report! server notes (list (diagnostics-test/marks:err notes "gamma" "undefined")))
  (diagnostics:report! linter notes (list (diagnostics-test/marks:warn notes "zeta" "long")))
  (check-equal? '(("gamma" error "undefined") ("zeta" warning "long")) (diagnostics-test/marks:all-seen notes)))

(test "diagnostics:in gives every one, those at a position, or those overlapping a range, ordered by start, then most severe first"
  (diagnostics:report! linter notes (list (diagnostics-test/marks:warn notes "gamma" "shadowed") (diagnostics-test/marks:warn notes "zeta" "long")))
  (let ([gamma (diagnostics-test/marks:word notes "gamma")])
    (check-equal? '(("gamma" error "undefined") ("gamma" warning "shadowed") ("zeta" warning "long")) (diagnostics-test/marks:all-seen notes))
    (check-equal? '(("gamma" error "undefined") ("gamma" warning "shadowed")) (map diagnostics-test/marks:seen (diagnostics:in notes gamma)))
    (check-equal? '() (map diagnostics-test/marks:seen (diagnostics:in notes (+ gamma 5))))
    (check-equal? '(("gamma" error "undefined") ("gamma" warning "shadowed")) (map diagnostics-test/marks:seen (diagnostics:in notes 1 (+ gamma 1))))
    (check-equal? '() (map diagnostics-test/marks:seen (diagnostics:in notes 1 gamma)))
    (check-equal? '(("gamma" error "undefined") ("gamma" warning "shadowed") ("zeta" warning "long"))
                  (map diagnostics-test/marks:seen (diagnostics:in notes gamma (+ (diagnostics-test/marks:word notes "zeta") 1))))))

(test "each severity has its layer type, at priorities 53 down to 50, so an error overlapping a warning is drawn inside it"
  (check-equal? '(53 52 51 50)
                (map (lambda (type) (buffers:layer-priority (buffers:layer notes type)))
                     (list diagnostics:error-marks diagnostics:warning-marks diagnostics:info-marks diagnostics:hint-marks)))
  (test-user:settle)
  (let ([faced (lambda (sxml face)
                 (filter (lambda (e) (equal? face (test-user:element-attribute e "data-face")))
                         (test-user:elements-with sxml "data-face")))])
    (check (exists (lambda (warning) (pair? (faced warning "diagnostic.error")))
                   (faced (test-user:screen) "diagnostic.warning")))))

(test "a report about an old version is placed by the edits since, its lines and columns counted on that version's content"
  (diagnostics:clear! server)
  (let ([then (buffers:version notes)])
    (buffers:replace! notes 1 1 "new line\n")
    (check (diagnostics:report! linter notes
             (list (diagnostics:make-diagnostic 1 6 (diagnostics:severity info) "first word")
                   (diagnostics:make-diagnostic '(2 . 0) '(2 . 5) (diagnostics:severity hint) "second line"))
             then))
    (check-equal? '(("alpha" info "first word") ("delta" hint "second line")) (diagnostics-test/marks:all-seen notes))
    (do ([i 0 (+ i 1)]) ((= i 1100)) (buffers:with-silent-edits notes (buffers:replace! notes 1 1 "x") (buffers:replace! notes 1 2 "")))
    (timers:set-idle! #t)
    (test-runner:wait-until (lambda () (not (buffers:document-at notes then))))
    (check-equal? #f (diagnostics:report! linter notes (list (diagnostics:make-diagnostic 1 2 (diagnostics:severity info) "late")) then))
    (check-equal? '(("alpha" info "first word") ("delta" hint "second line")) (diagnostics-test/marks:all-seen notes))
    (buffers:replace! notes 1 10 "")))

(test "a range the edits since have emptied is dropped; a range empty as sent is widened to what stands there now"
  (let* ([racey (buffers:make "racey" "alpha beta gamma\n")] [v0 (buffers:version racey)])
    (buffers:replace! racey 7 12 "")
    (diagnostics:report! linter racey (list (diagnostics:make-diagnostic 7 11 (diagnostics:severity warning) "beta is bad")) v0)
    (check-equal? '("alpha gamma\n" ()) (list (diagnostics-test/marks:text racey) (diagnostics-test/marks:all-seen racey)))
    (let ([v1 (buffers:version racey)])
      (buffers:replace! racey 7 12 "delta")
      (diagnostics:report! linter racey (list (diagnostics:make-diagnostic 7 12 (diagnostics:severity warning) "gamma is bad")) v1)
      (check-equal? '("alpha delta\n" ()) (list (diagnostics-test/marks:text racey) (diagnostics-test/marks:all-seen racey)))
      (diagnostics:report! linter racey (list (diagnostics:make-diagnostic 7 7 (diagnostics:severity warning) "sent empty")) v1)
      (check-equal? '(("delta" warning "sent empty")) (diagnostics-test/marks:all-seen racey)))))

(test "a report's arguments are checked"
  (check-raises (raised? 'diagnostics:report! "not a version of the buffer")
                (diagnostics:report! linter notes '() (+ (buffers:version notes) 1)))
  (check-raises (raised? 'diagnostics:report! "not a source") (diagnostics:report! 'linter notes '()))
  (check-raises (raised? 'diagnostics:report! "neither a buffer nor an absolute path") (diagnostics:report! linter "notes" '())))

(test "an empty range, or a line and column with no end, is widened to the symbol at its start, else to its line's end, else to its line; on an empty line it is dropped"
  (let ([spaced (buffers:make "spaced" "f(x)  + 1\nab  \n\n")])
    (diagnostics:report! linter spaced
      (list (diagnostics:make-diagnostic 3 3 (diagnostics:severity info) "in x")
            (diagnostics:make-diagnostic '(1 . 5) #f (diagnostics:severity info) "after the call")
            (diagnostics:make-diagnostic '(2 . 4) '(2 . 4) (diagnostics:severity info) "at the line's end")
            (diagnostics:make-diagnostic '(3 . 0) #f (diagnostics:severity info) "empty line")))
    (check-equal? '(("x" info "in x") (" + 1" info "after the call") ("ab  " info "at the line's end")) (diagnostics-test/marks:all-seen spaced))))

(test "text typed at either edge of a mark stays outside it; a marked word deleted and typed again leaves no mark, and diagnostics:changed is called"
  (check-equal? "alpha beta gamma\ndelta epsilon\n\nzeta eta\n" (diagnostics-test/marks:text notes))
  (diagnostics:report! linter notes (list (diagnostics-test/marks:warn notes "beta" "vague")))
  (let ([changes 0])
    (define (note-change where) (set! changes (+ changes 1)))
    (hooks:add! diagnostics:changed note-change)
    (buffers:insert! notes (diagnostics-test/marks:word notes "beta") "<")
    (buffers:insert! notes (+ (diagnostics-test/marks:word notes "beta") 4) ">")
    (check-equal? '("alpha <beta> gamma\ndelta epsilon\n\nzeta eta\n" (("beta" warning "vague")) (("beta" (diagnostic.warning) "vague")))
                  (list (diagnostics-test/marks:text notes) (diagnostics-test/marks:all-seen notes) (diagnostics-test/marks:marks notes)))
    (buffers:replace! notes (diagnostics-test/marks:word notes "beta") (+ (diagnostics-test/marks:word notes "beta") 4) "")
    (buffers:insert! notes (diagnostics-test/marks:word notes "<>") "beta")
    (check-equal? '(() () 1) (list (diagnostics-test/marks:all-seen notes) (diagnostics-test/marks:marks notes) changes))
    (hooks:remove! diagnostics:changed note-change))
  (diagnostics:report! linter notes (list (diagnostics-test/marks:warn notes "beta" "vague")))
  (check-equal? '(("beta" (diagnostic.warning) "vague")) (diagnostics-test/marks:marks notes)))

(test "with the mode off the marks are hidden and the diagnostics kept and listed; on again draws them"
  (diagnostics-test/marks:mode! notes #f)
  (check-equal? '(() (("beta" warning "vague"))) (list (diagnostics-test/marks:marks notes) (diagnostics-test/marks:all-seen notes)))
  (diagnostics-test/marks:mode! notes #t)
  (check-equal? '(("beta" (diagnostic.warning) "vague")) (diagnostics-test/marks:marks notes)))

(define folder (string-append (getenv "HOME") "/project"))

(test "a report to a path no buffer visits keeps lines and columns and is listed under its folder; visiting the file makes them spans"
  (mkdir folder)
  (let ([path (string-append folder "/a.txt")])
    (with-output-to-file path (lambda () (display "one\ntwo bad\n")))
    (diagnostics:report! linter path (list (diagnostics:make-diagnostic '(2 . 4) '(2 . 7) (diagnostics:severity error) "bad")))
    (check-equal? (list (list path '(((2 . 4) (2 . 7)) error "bad")))
                  (map (lambda (d) (list (diagnostics:diagnostic-path d) (diagnostics-test/marks:seen d))) (diagnostics:under folder)))
    (check-raises (raised? 'diagnostics:report! "positions in a report to a path")
                  (diagnostics:report! linter path (list (diagnostics:make-diagnostic 1 2 (diagnostics:severity error) "x"))))
    (let ([a (files:visit path)])
      (diagnostics-test/marks:mode! a #t)
      (check-equal? '((("bad" error "bad")) (("bad" (diagnostic.error) "bad")) (("bad" error "bad")))
                    (list (diagnostics-test/marks:all-seen a) (diagnostics-test/marks:marks a) (map diagnostics-test/marks:seen (diagnostics:under folder))))
      (diagnostics:clear! linter a)
      (check-equal? '(() (("beta" warning "vague"))) (list (diagnostics-test/marks:all-seen a) (diagnostics-test/marks:all-seen notes)))
      (diagnostics:clear! linter)
      (check-equal? '() (diagnostics-test/marks:all-seen notes)))))

(test "the at-point source gives each diagnostic's text at point, all of it in error, warning or success by its severity, and nothing where the mode is off"
  (diagnostics:report! linter notes (list (diagnostics-test/marks:warn notes "beta" "vague") (diagnostics-test/marks:err notes "beta" "wrong")
                                          (diagnostics-test/marks:info notes "beta" "fine")))
  (views:set-point! (layout:selected-view) (diagnostics-test/marks:word notes "beta"))
  (check-equal? '(("wrong" ((0 5 error))) ("vague" ((0 5 warning))) ("fine" ((0 4 success))))
                (map (lambda (doc) (list (docs-at-point:doc-text doc) (docs-at-point:doc-spans doc)))
                     (diagnostics:at-point (layout:selected-view))))
  (diagnostics-test/marks:mode! notes #f)
  (check-equal? #f (diagnostics:at-point (layout:selected-view)))
  (diagnostics-test/marks:mode! notes #t))

(test "a source belongs to the module that made it: unloading the module clears its diagnostics"
  (diagnostics:report! linter notes (list (diagnostics-test/marks:warn notes "beta" "vague")))
  (check (diagnostics-test/reporter:report-bad! notes))
  (check-equal? '(("beta" warning "vague") ("delta" error "bad")) (diagnostics-test/marks:all-seen notes))
  (unload-owner! (module-owner '(diagnostics-test reporter)))
  (check-equal? '(("beta" warning "vague")) (diagnostics-test/marks:all-seen notes)))
