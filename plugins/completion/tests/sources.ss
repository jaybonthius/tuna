(import (tuna) (test) (test-user) (test-runner) (saved) (options) (tables) (jobs) (layout) (minibuffer) (completion) (completion-list) (editing)
        (only (completion matcher) store-matches make-store pattern-spans)
        (sessions))

(saved:define-saved h '() list?)

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

(define (syntax-error? message)
  (lambda (c) (and (syntax-violation? c) (string=? message (condition-message c)))))

(define (quit! r)
  (test-user:press! "C-g")
  (check-raises cancelled? (sessions:result r)))

(define (after-slash input)
  (let loop ([i (string-length input)])
    (cond [(= i 0) 0] [(char=? (string-ref input (- i 1)) #\/) i] [else (loop (- i 1))])))

(define (count-is? s n) (lambda () (= (completion:matches-count (completion:session-matches s)) n)))

(test "a source needs one of candidates, job and stream; a clause twice or an unknown clause is a syntax error"
  (for-each
    (lambda (module message)
      (check-raises (syntax-error? message) (load-module! (list 'bad-source module))))
    '(no-candidates candidates-and-job job-and-stream title-twice unknown-clause preview-show-only)
    '("a candidates, job or stream clause is required"
      "more than one of the candidates, job and stream clauses"
      "more than one of the candidates, job and stream clauses"
      "clause given twice"
      "invalid clause"
      "invalid clause")))

(test "a source's clauses are checked when it is made"
  (for-each
    (lambda (make message) (check-raises (raised? 'completion:source message) (make)))
    (list (lambda () (completion:source (candidates 5)))
          (lambda () (completion:source (candidates #f)))
          (lambda () (completion:source (candidates (vector "a")) (rank (vector 1 2))))
          (lambda () (completion:source (stream 5)))
          (lambda () (completion:source (stream #f)))
          (lambda () (completion:source (job 5 #f)))
          (lambda () (completion:source (candidates (vector)) (styles 5)))
          (lambda () (completion:source (candidates (vector "a")) (exit 'done)))
          (lambda () (completion:source (candidates (vector "a")) (group 1)))
          (lambda () (completion:source (candidates (vector "a")) (group values 2)))
          (lambda () (completion:source (candidates (vector "a")) (narrow "b")))
          (lambda () (completion:source (candidates (vector "a")) (narrow #\space))))
    '("neither a vector of candidates nor a procedure" "neither a vector of candidates nor a procedure"
      "not a vector of fixnums, one for each candidate" "not a procedure" "not a procedure" "not a worker"
      "not a list of styles" "not a procedure" "not a procedure" "neither a procedure nor #f"
      "neither a character other than a space nor #f" "neither a character other than a space nor #f"))
  (check (completion:source? (completion:source (candidates (vector "a")))))
  (check (not (completion:source? (vector "a")))))

(test "the reading procedures and the session's readers check their arguments"
  (check-raises (raised? 'completion:read "not a list of sources") (completion:read "? " (list 1)))
  (check-raises (raised? 'completion:start "neither first nor none")
    (completion:start (layout:selected-view) '() values void 'all))
  (check-raises (raised? 'completion:text "not a session") (completion:text 'session 0))
  (check-raises (raised? 'completion:make-matcher "not a procedure") (completion:make-matcher 1 2 3))
  (check-raises (raised? 'completion:matches-count "not matches") (completion:matches-count (vector)))
  (check-raises (raised? 'completion:matches-index "not matches") (completion:matches-index (vector) 0)))

(test "a procedure source is called again when the prefix its split gives changes, and choosing replaces only the query"
  (let* ([calls '()]
         [r (sessions:start!
              (lambda ()
                (completion:read-or-input "Path: "
                  (list (completion:source
                          (candidates (lambda (prefix) (set! calls (cons prefix calls)) (vector (string-append "f-" prefix) "g")))
                          (split after-slash)))
                  h)))])
    (saved:set! h '())
    (test-user:type! "a/b/f")
    (check-equal? '("" "a/" "a/b/") (reverse calls))
    (check-equal? '("f-a/b/") (sessions:texts (sessions:session)))
    (test-user:press! "TAB")
    (check-equal? "a/b/f-a/b/" (sessions:input))
    (test-user:press! "RET")
    (check-equal? "g" (sessions:result r))
    (check-equal? '("a/b/f-a/b/g") (h))))

(test "RET chooses a procedure source's selected match without matching the text it puts in"
  (let* ([calls 0]
         [r (sessions:start!
              (lambda ()
                (completion:read "? "
                  (list (completion:source
                          (candidates (lambda (prefix) (set! calls (+ calls 1)) (if (string=? prefix "") (vector "a/" "b/") (vector "c"))))
                          (split after-slash)))
                  #f)))])
    (test-user:press! "C-n RET")
    (check-equal? "b/" (sessions:result r))
    (check-equal? 1 calls)))

(jobs:define-worker (two-rounds input emit receive)
  (receive)
  (emit (vector "one" "two"))
  (emit 'clear)
  (emit (vector "three")))

(test "a job's clear drops what it emitted before, whose matches then name nothing"
  (let* ([r (sessions:start! (lambda () (completion:read "? " (list (completion:source (job two-rounds #f))) #f)))]
         [s (sessions:session)])
    (sessions:wait-matches s)
    (check-equal? '("three") (sessions:texts s))
    (check-equal? #f (completion:session-busy? s))
    (check-equal? '(2) (sessions:matches s))
    (for-each
      (lambda (m) (check-raises (raised? 'completion:text "not a match of the session") (completion:text s m)))
      '(0 1 3))
    (quit! r)))

(test "a stream gets each new prefix and the end-of-file object when the session ends; it is busy from a prefix until done"
  (let* ([prefixes '()] [emit #f]
         [letters (lambda (e) (set! emit e) (lambda (prefix) (set! prefixes (cons prefix prefixes))))]
         [r (sessions:start!
              (lambda () (completion:read "? " (list (completion:source (stream letters) (split string-length))) #f)))]
         [s (sessions:session)])
    (check-equal? #t (completion:session-busy? s))
    (emit (vector "ab" "ac"))
    (emit 'done)
    (sessions:wait-matches s)
    (check-equal? '("ab" "ac") (sessions:texts s))
    (test-user:type! "x")
    (check-equal? #t (completion:session-busy? s))
    (emit 'clear)
    (emit (vector "xy"))
    (emit 'done)
    (sessions:wait-matches s)
    (check-equal? '("xy") (sessions:texts s))
    (quit! r)
    (check-equal? (list "" "x" (eof-object)) (reverse prefixes))
    (emit (vector "late"))
    (check-equal? '("xy") (sessions:texts s))))

(test "while a stream's pattern holds its new matches go at the end of the same matches; a new pattern or a clear gives new ones"
  (let* ([emit #f]
         [r (sessions:start!
              (lambda () (completion:read "? " (list (completion:source (stream (lambda (e) (set! emit e) (lambda (prefix) (void)))) (styles (list completion:substring)))) #f)))]
         [s (sessions:session)])
    (emit (vector "apple" "berry" "banana"))
    (test-runner:wait-until (count-is? s 3))
    (let ([all (completion:session-matches s)])
      (emit (vector "cherry" "apricot"))
      (test-runner:wait-until (count-is? s 5))
      (check (eq? all (completion:session-matches s)))
      (check-equal? '("apple" "berry" "banana" "cherry" "apricot") (sessions:texts s))
      (test-user:type! "ap")
      (test-runner:wait-until (count-is? s 2))
      (let ([ap (completion:session-matches s)])
        (check (not (eq? all ap)))
        (check-equal? '("apple" "apricot") (sessions:texts s))
        (emit (vector "grape" "kiwi" "papaya"))
        (test-runner:wait-until (count-is? s 4))
        (check (eq? ap (completion:session-matches s)))
        (check-equal? '("apple" "apricot" "grape" "papaya") (sessions:texts s))
        (emit 'clear)
        (emit (vector "map"))
        (test-runner:wait-until (count-is? s 1))
        (check (not (eq? ap (completion:session-matches s))))
        (check-equal? '("map") (sessions:texts s))))
    (let ([ms (completion:session-matches s)])
      (check (completion:matches? ms))
      (check-raises (raised? 'completion:matches-ref "not a place in the matches") (completion:matches-ref ms 1))
      (check-equal? 0 (completion:matches-index ms (completion:matches-ref ms 0)))
      (check-equal? #f (completion:matches-index ms -1)))
    (quit! r)))

(test "a stream that emits prefer-input selects no new match while the input is its prefix, so RET takes the input"
  (let* ([listing (lambda (emit)
                    (lambda (prefix)
                      (unless (eof-object? prefix)
                        (emit 'clear)
                        (unless (string=? prefix "") (emit 'prefer-input))
                        (emit (vector "ab" "abc"))
                        (emit 'done))))]
         [r (sessions:start!
              (lambda () (completion:read-or-input "? " (list (completion:source (stream listing) (split after-slash))) #f)))]
         [s (sessions:session)])
    (check-equal? "ab" (sessions:selected-text s))
    (test-user:type! "x/")
    (check-equal? #f (sessions:selected-text s))
    (test-user:type! "a")
    (check-equal? "ab" (sessions:selected-text s))
    (test-user:press! "DEL")
    (check-equal? #f (sessions:selected-text s))
    (test-user:press! "C-n")
    (check-equal? "ab" (sessions:selected-text s))
    (completion:select! s #f)
    (test-user:press! "RET")
    (check-equal? "x/" (sessions:result r))))

(test "a read's first match waits for its setups, so a stream's first prefix is the input an outer setup gives, once"
  (let* ([given '()]
         [recorder (lambda (emit) (lambda (prefix) (unless (eof-object? prefix) (set! given (cons prefix given)))))]
         [r (sessions:start!
              (lambda ()
                (minibuffer:call-with-setup (lambda (p) (minibuffer:set-input! p "ab/"))
                  (lambda () (completion:read "? " (list (completion:source (stream recorder) (split after-slash))) #f)))))])
    (check-equal? '("ab/") given)
    (quit! r)))

(test "RET with none selected chooses the candidate whose text is the input, among more than the main thread matches"
  (let* ([many (lambda (emit)
                 (lambda (prefix)
                   (unless (eof-object? prefix)
                     (emit (list->vector (map (lambda (i) (cons (format "item ~a" i) i)) (iota 5000))))
                     (emit 'done))))]
         [r (sessions:start! (lambda () (completion:read "? " (list (completion:source (stream many))) #f)))])
    (test-user:type! "item 4321")
    (completion:select! (sessions:session) #f)
    (test-user:press! "RET")
    (test-runner:wait-until (lambda () (not (sessions:waiting? r))))
    (check-equal? 4321 (sessions:result r))))

(jobs:define-worker (slow-match input emit receive)
  (import (completion matcher))
  (serve emit (case-lambda [() (let ([m (receive)]) (sleep (make-time 'time-duration 200000000 0)) m)] [(s) (receive s)])))

(test "RET with none selected is answered when the stream says done before its match job looks"
  (options:set! completion:matcher
    (completion:make-matcher (lambda (pattern texts ranks groups) (store-matches (make-store texts ranks groups) pattern))
                             pattern-spans slow-match))
  (let* ([emit #f]
         [r (sessions:start!
              (lambda () (completion:read "? " (list (completion:source (stream (lambda (e) (set! emit e) (lambda (prefix) (void)))))) #f)))]
         [s (sessions:session)])
    (emit (vector "ab" "abc"))
    (test-user:type! "ab")
    (test-runner:wait-until (lambda () (equal? '("ab" "abc") (sessions:texts s))))
    (completion:select! s #f)
    (test-user:press! "RET")
    (emit 'done)
    (test-runner:wait-until (lambda () (not (sessions:waiting? r))))
    (check-equal? "ab" (sessions:result r)))
  (options:unset! completion:matcher))

(jobs:define-worker (plain-worker input emit receive)
  (import (completion matcher))
  (serve emit receive))

(test "a matcher set in completion:matcher does the matching and gives the spans"
  (options:set! completion:matcher
    (completion:make-matcher (lambda (pattern texts ranks groups) (list->vector (reverse (iota (vector-length texts)))))
                             (lambda (pattern text) '())
                             plain-worker))
  (check (completion:matcher? (completion:matcher)))
  (let ([r (sessions:start! (lambda () (completion:read "? " (list (completion:source (candidates (vector "a" "b" "c")))) #f)))])
    (test-user:type! "zzz")
    (check-equal? '("c" "b" "a") (sessions:texts (sessions:session)))
    (check-equal? '() (completion:spans (sessions:session) 0))
    (quit! r))
  (options:unset! completion:matcher)
  (check (eq? completion:default-matcher (completion:matcher))))

(test "a stream that returns no receiver is reported at the read's first match, and the read waits"
  (let* ([r #f]
         [reported (sessions:reports-during
                     (lambda () (set! r (sessions:start! (lambda () (completion:read "? " (list (completion:source (stream (lambda (emit) 5)))) #f))))))])
    (check-equal? '("a stream returned what is not a receiver") (map condition-message reported))
    (check-equal? 0 (completion:matches-count (completion:session-matches (sessions:session))))
    (quit! r)))

(completion:define-category probe-category "Candidates whose details the test shows.")

(define (annotations s)
  (map (lambda (m) (cons (completion:text s m) (completion:annotation s m))) (sessions:matches s)))

(jobs:define-worker (details-stream n emit)
  (emit (vector (vector "one" 1 'first)))
  (emit (vector "two")))

(test "a candidate's details, its third element, reach its category's annotator with its value; one without gives #f"
  (tables:set! completion:annotators probe-category
    (lambda (session) (lambda (value details) (list (format "~s ~s" value details)))))
  (let ([r (sessions:start!
             (lambda ()
               (completion:read "Probe: "
                 (list (completion:source (candidates (vector (vector "alpha" 'a '(1 . 2)) "beta" (cons "gamma" 'g))) (category probe-category) (in-order)))
                 #f)))])
    (check-equal? '(("alpha" "a (1 . 2)") ("beta" "\"beta\" #f") ("gamma" "g #f")) (annotations (sessions:session)))
    (quit! r))
  (let ([r (sessions:start! (lambda () (completion:read "Probe: " (list (completion:source (job details-stream 0) (category probe-category))) #f)))])
    (sessions:wait-matches (sessions:session))
    (check-equal? '(("one" "1 first") ("two" "\"two\" #f")) (annotations (sessions:session)))
    (quit! r))
  (let ([r (sessions:start! (lambda () (completion:read "Plain: " (list (completion:source (candidates (vector "x")))) #f)))])
    (check-equal? '(("x")) (annotations (sessions:session)))
    (quit! r))
  (tables:remove! completion:annotators probe-category))

(jobs:define-worker (project-files root emit)
  (let walk ([dir root])
    (let*-values ([(paths) (map (lambda (name) (string-append dir "/" name))
                                (remp (lambda (name) (char=? (string-ref name 0) #\.)) (directory-list dir)))]
                  [(dirs files) (partition (lambda (path) (and (not (file-symbolic-link? path)) (file-directory? path))) paths)])
      (emit (list->vector files))
      (for-each walk dirs))))

(test "a job streams its worker's candidates, and the session is busy until the worker ends"
  (let ([root (string-append (getenv "HOME") "/project")])
    (mkdir root)
    (mkdir (string-append root "/sub"))
    (for-each (lambda (name) (call-with-output-file (string-append root "/" name) (lambda (p) (put-string p "x"))))
      '("a.txt" "sub/b.sls" ".hidden"))
    (let* ([r (sessions:start!
                (lambda () (completion:read "Find file in project: " (list (completion:source (job project-files root) (category completion:file-category))) #f)))]
           [s (sessions:session)])
      (sessions:wait-matches s)
      (check-equal? (list (string-append root "/a.txt") (string-append root "/sub/b.sls")) (list-sort string<? (sessions:texts s)))
      (check-equal? (list completion:file-category) (completion:session-categories s))
      (quit! r))))

(test "a search that asks as you type waits for 3 characters and 0.2 seconds without typing by default"
  (check-equal? 3 (completion:async-min-input))
  (check-equal? 0.2 (completion:async-delay)))
