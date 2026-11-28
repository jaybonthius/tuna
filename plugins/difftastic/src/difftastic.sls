#!tuna
(import (diff-sections) (diff) (jobs) (processes) (options) (tables))

(define %self (current-owner))

(options:define-option program "difft" string? "The difftastic program run."
  (lambda (v) (%program-changed!)))

(options:define-option arguments '() (lambda (v) (and (list? v) (for-all string? v)))
  "Arguments added to every run of difftastic, such as \"--ignore-comments\"; each is one word to the shell."
  (lambda (v) (diff-sections:forget! refiner)))

;; The version that added aligned_lines, which the two-column layout reads.
(define %minimum-version '(0 68))

;; Only the fields read are kept, as plain data a worker can send:
;; difftastic's JSON is unstable by its author's word.
(jobs:define-worker (%reader output emit)
  (import (json))
  (define (field object name) (let ([p (assoc name object)]) (and p (not (eq? (cdr p) 'null)) (cdr p))))
  (define (line-of side) (lambda (entry) (field entry side)))
  (define (novel-of side line)
    (if line
        (map (lambda (c) (list side (+ (field line "line_number") 1) (field c "start") (field c "end")))
             (vector->list (or (field line "changes") '#())))
        '()))
  (define (file-of object)
    (let ([chunks (or (field object "chunks") '#())] [aligned (or (field object "aligned_lines") '#())])
      (vector (field object "path") (field object "status")
              (apply append
                (map (lambda (chunk)
                       (apply append (map (lambda (entry) (append (novel-of 'old (field entry "lhs")) (novel-of 'new (field entry "rhs"))))
                                          (vector->list chunk))))
                     (vector->list chunks)))
              (map (lambda (pair)
                     (let ([l (vector-ref pair 0)] [r (vector-ref pair 1)])
                       (cons (and (fixnum? l) (+ l 1)) (and (fixnum? r) (+ r 1)))))
                   (vector->list aligned)))))
  (emit (guard (c [(error? c) (vector 'failed (if (message-condition? c) (condition-message c) "unreadable output"))])
          (let loop ([lines (let split ([i 0] [start 0])
                              (cond
                                [(fx= i (bytevector-length output))
                                 (if (fx< start i) (list (let ([p (make-bytevector (fx- i start))]) (bytevector-copy! output start p 0 (fx- i start)) p)) '())]
                                [(fx= (bytevector-u8-ref output i) 10)
                                 (cons (let ([p (make-bytevector (fx- i start))]) (bytevector-copy! output start p 0 (fx- i start)) p)
                                       (split (fx+ i 1) (fx+ i 1)))]
                                [else (split (fx+ i 1) start)]))])
            (if (null? lines)
                '()
                (let ([object (bytevector->json (car lines))])
                  (unless (and (list? object) (string? (field object "path")) (string? (field object "status")))
                    (error 'difftastic "an object without its path or status"))
                  (cons (file-of object) (loop (cdr lines)))))))))

(define %version-checked? #f)

(define %unusable #f)

(define %warned? #f)

(define (%warn! reason)
  (unless %warned?
    (set! %warned? #t)
    (report (condition (make-warning) (make-who-condition 'difftastic) (make-message-condition (string-append "difft could not be used: " reason))))))

(define (%version-of text)
  (let loop ([i 0])
    (cond
      [(fx= i (string-length text)) #f]
      [(char-numeric? (string-ref text i))
       (let parts ([j i] [start i] [acc '()])
         (cond
           [(and (fx< j (string-length text)) (char-numeric? (string-ref text j))) (parts (fx+ j 1) start acc)]
           [(and (fx< j (string-length text)) (char=? (string-ref text j) #\.))
            (parts (fx+ j 1) (fx+ j 1) (cons (string->number (substring text start j)) acc))]
           [else (reverse (cons (string->number (substring text start j)) acc))]))]
      [else (loop (fx+ i 1))])))

(define (%at-least? version minimum)
  (cond
    [(null? minimum) #t]
    [(null? version) #f]
    [(> (car version) (car minimum)) #t]
    [(< (car version) (car minimum)) #f]
    [else (%at-least? (cdr version) (cdr minimum))]))

;; The version is read once a session, in the first refinement's task,
;; so nothing waits for it.
(define (%check-version!)
  (unless %version-checked?
    (set! %version-checked? #t)
    (let ([version (guard (c [(not (cancelled? c)) #f])
                     (let-values ([(status out err) (processes:run (program) '("--version"))])
                       (and (eqv? status 0) (%version-of (utf8->string out)))))])
      (cond
        [(not version) (set! %unusable (string-append (program) " did not run"))]
        [(not (%at-least? version %minimum-version)) (set! %unusable (string-append (program) " is older than 0.68"))]))))

(define (available?) (not %unusable))

;; Answers of another program, or another version, are not this one's.
(define (%program-changed!)
  (set! %version-checked? #f)
  (set! %unusable #f)
  (set! %warned? #f)
  (diff-sections:forget! refiner))

(define (%quoted word)
  (string-append "'" (apply string-append (map (lambda (c) (if (char=? c #\') "'\\''" (string c))) (string->list word))) "'"))

(define (%external-command)
  (fold-left (lambda (command word) (string-append command " " (%quoted word)))
             "DFT_UNSTABLE=yes" (append (list (program) "--display" "json") (arguments))))

(define (%parse output)
  (suspend
    (lambda (resume)
      (let ([result #f])
        (jobs:start %reader output (lambda (v) (set! result v))
          (lambda (ended) (resume (lambda () (if (or (condition? ended) ended) (vector 'failed "the reader stopped") result)))))))))

(define (%refinements files parsed)
  (fold-right
    (lambda (f acc)
      (let ([object (find (lambda (o) (equal? (vector-ref o 0) (diff:file-path f))) parsed)])
        (if (and object (or (equal? (vector-ref object 1) "unchanged")
                            (and (equal? (vector-ref object 1) "changed") (pair? (vector-ref object 3)))))
            (cons (diff-sections:make-refinement (diff:file-path-bytes f) (diff:file-old-blob f) (diff:file-new-blob f)
                                                 (vector-ref object 2) (vector-ref object 3)
                                                 (equal? (vector-ref object 1) "unchanged"))
                  acc)
            acc)))
    '() files))

(define (%refine request)
  (call-as-owner %self
    (lambda ()
      (spawn-task
        (lambda (restore)
          (let ([answer
                 (guard (c [(not (cancelled? c))
                            (%warn! (if (message-condition? c) (condition-message c) "it raised"))
                            '()])
                   (%check-version!)
                   (if %unusable
                       (begin (%warn! %unusable) '())
                       (let ([parsed (%parse ((diff-sections:request-run request) (%external-command)))])
                         (if (vector? parsed)
                             (begin (%warn! (vector-ref parsed 1)) '())
                             (%refinements (diff-sections:request-files request) parsed)))))])
            (diff-sections:deliver! request answer)))))))

(define refiner (diff-sections:make-refiner "difftastic" available? %refine))

(options:set! diff-sections:refiner refiner)
(tables:set! diff-sections:refiners refiner #t)
