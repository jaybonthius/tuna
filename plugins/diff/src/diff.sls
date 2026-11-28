#!tuna
(import (jobs) (prefix (diff parse) parsed:))

(define %self (current-owner))

(jobs:define-worker (%parser output emit)
  (import (diff parse))
  (emit (guard (c [(error? c)
                   (vector 'failed (if (message-condition? c) (condition-message c) "failed")
                           (if (irritants-condition? c)
                               (map (lambda (x) (if (string? x) x (format "~s" x))) (condition-irritants c))
                               '()))])
          (parse-diff output))))

(module %internals
  (job-result stop-waiting! check-file check-hunk check-line hunk-index combined-error
   file-patch-bytes hunks-patch-bytes lines-patch-bytes)

  ;; Unloading this module stops its jobs without ending them, so it
  ;; resumes the tasks waiting for them itself.
  (define waiting '())

  (define (take-waiter! w)
    (and (memq w waiting)
         (begin (set! waiting (remq w waiting)) #t)))

  (define (failure? v) (and (vector? v) (fx= (vector-length v) 3) (eq? (vector-ref v 0) 'failed)))

  (define (job-result output)
    (let ([job #f] [result #f])
      (guard (c [#t (when job (jobs:stop! job)) (raise c)])
        (suspend
          (lambda (resume)
            (let ([w resume])
              (call-as-owner %self
                (lambda ()
                  (set! job
                    (jobs:start %parser output
                      (lambda (v) (set! result v))
                      (lambda (ended)
                        (when (take-waiter! w)
                          (resume
                            (lambda ()
                              (cond
                                [(condition? ended) (raise ended)]
                                [ended (assertion-violation 'diff:parse "the job was stopped")]
                                [(failure? result)
                                 (apply error 'diff:parse (vector-ref result 1) (vector-ref result 2))])
                              result))))))))
              (set! waiting (cons w waiting))))))))

  (define (stop-waiting!)
    (let ([stopped waiting])
      (set! waiting '())
      (for-each (lambda (resume)
                  (resume (lambda () (error 'diff:parse "the diff plugin was unloaded"))))
                stopped)))

  (define (check-file who v)
    (unless (parsed:file? v)
      (assertion-violation who "not a file diff" v)))

  (define (check-hunk who v)
    (unless (parsed:hunk? v)
      (assertion-violation who "not a hunk" v)))

  (define (check-line who v)
    (unless (parsed:line? v)
      (assertion-violation who "not a line of a hunk" v)))

  ;; A hunk may be a copy, as one kept in a document's node is, so hunks
  ;; are compared by value.
  (define (hunk-index who file hunk)
    (let loop ([hunks (parsed:file-hunks file)] [i 0])
      (cond
        [(null? hunks) (assertion-violation who "not hunks of this file" hunk)]
        [(equal? (car hunks) hunk) i]
        [else (loop (cdr hunks) (fx+ i 1))])))

  (define combined-error "Cannot un-/stage resolution hunks.  Stage the whole file")

  (define (refuse-unpatchable who file)
    (when (parsed:file-binary? file)
      (error who "binary files have no hunks"))
    (when (parsed:file-combined? file)
      (error who combined-error)))

  (define (put-string out s) (put-bytevector out (string->utf8 s)))

  (define (quoted? bytes)
    (let ([n (bytevector-length bytes)])
      (let loop ([i 0])
        (and (fx< i n)
             (let ([b (bytevector-u8-ref bytes i)])
               (or (fx< b 32) (fx= b 34) (fx= b 92) (fx= b 127) (loop (fx+ i 1))))))))

  ;; As git quotes a path holding a control byte, " or \, with its
  ;; prefix inside the quotes.
  (define (put-path out prefix bytes)
    (cond
      [(quoted? bytes)
       (put-u8 out 34)
       (put-string out prefix)
       (let ([n (bytevector-length bytes)])
         (do ([i 0 (fx+ i 1)]) ((fx= i n))
           (let ([b (bytevector-u8-ref bytes i)])
             (case b
               [(7) (put-string out "\\a")]
               [(8) (put-string out "\\b")]
               [(9) (put-string out "\\t")]
               [(10) (put-string out "\\n")]
               [(11) (put-string out "\\v")]
               [(12) (put-string out "\\f")]
               [(13) (put-string out "\\r")]
               [(34) (put-string out "\\\"")]
               [(92) (put-string out "\\\\")]
               [else
                (if (or (fx< b 32) (fx= b 127))
                    (put-string out (string-append "\\" (let ([o (number->string b 8)])
                                                         (string-append (make-string (fx- 3 (string-length o)) #\0) o))))
                    (put-u8 out b))]))))
       (put-u8 out 34)]
      [else
       (put-string out prefix)
       (put-bytevector out bytes)]))

  (define (put-modification-header out file)
    (let ([path (parsed:file-path-bytes file)])
      (put-string out "diff --git ") (put-path out "a/" path) (put-string out " ") (put-path out "b/" path)
      (put-string out "\n--- ") (put-path out "a/" path)
      (put-string out "\n+++ ") (put-path out "b/" path)
      (put-string out "\n")))

  ;; A partial patch modifies the new path, so it carries no rename, mode
  ;; or new-file line that would apply more than the selection; git's
  ;; header stays where the patch is the whole added or deleted file, and
  ;; where a deleted file applied in reverse must be made again.
  (define (put-header out file reverse? whole?)
    (let ([status (parsed:file-status file)])
      (cond
        [(or (and whole? (memq status '(added deleted))) (and reverse? (eq? status 'deleted)))
         (put-bytevector out (parsed:file-header file))
         #t]
        [else (put-modification-header out file) #f])))

  (define (put-hunk out old-start old-count new-start new-count tail lines git-starts?)
    (let ([old-start (if (and (not git-starts?) (fx= old-start 0) (fx> old-count 0)) 1 old-start)]
          [new-start (if (and (not git-starts?) (fx= new-start 0) (fx> new-count 0)) 1 new-start)])
      (put-string out (format "@@ -~a,~a +~a,~a @@" old-start old-count new-start new-count))
      (put-bytevector out tail)
      (put-string out "\n")
      (for-each
        (lambda (line)
          (put-bytevector out (parsed:line-prefix line))
          (put-bytevector out (parsed:line-bytes line))
          (put-string out "\n")
          (when (parsed:line-no-newline? line)
            (put-string out "\\ No newline at end of file\n")))
        lines)))

  (define (line kind bytes no-newline?)
    (vector 'diff-line kind (case kind [(added) #vu8(43)] [(removed) #vu8(45)] [else #vu8(32)]) bytes no-newline?))

  ;; The marker may follow only the last line of its side, so a line
  ;; that carries it and has later lines on its side gains its newline;
  ;; a context line whose sides then differ becomes a removal and an
  ;; addition, each with its own marker.
  (define (fix-markers lines)
    (let* ([indexed (let loop ([ls lines] [i 0] [acc '()])
                      (if (null? ls) (reverse acc) (loop (cdr ls) (fx+ i 1) (cons (cons i (car ls)) acc))))]
           [last-of (lambda (keep?)
                      (fold-left (lambda (last p) (if (keep? (parsed:line-kind (cdr p))) (car p) last)) -1 indexed))]
           [last-old (last-of (lambda (k) (memq k '(context removed))))]
           [last-new (last-of (lambda (k) (memq k '(context added))))])
      (fold-right
        (lambda (p acc)
          (let* ([i (car p)] [l (cdr p)] [kind (parsed:line-kind l)] [nonl? (parsed:line-no-newline? l)]
                 [old-nonl? (and nonl? (memq kind '(context removed)) (fx= i last-old))]
                 [new-nonl? (and nonl? (memq kind '(context added)) (fx= i last-new))])
            (case kind
              [(context)
               (if (eq? (and old-nonl? #t) (and new-nonl? #t))
                   (cons (line 'context (parsed:line-bytes l) (and old-nonl? #t)) acc)
                   (cons* (line 'removed (parsed:line-bytes l) (and old-nonl? #t))
                          (line 'added (parsed:line-bytes l) (and new-nonl? #t))
                          acc))]
              [(removed) (cons (line 'removed (parsed:line-bytes l) (and old-nonl? #t)) acc)]
              [else (cons (line 'added (parsed:line-bytes l) (and new-nonl? #t)) acc)])))
        '() indexed)))

  (define (with-output thunk)
    (let-values ([(out done) (open-bytevector-output-port)])
      (thunk out)
      (done)))

  (define (file-patch-bytes who file)
    (refuse-unpatchable who file)
    (with-output
      (lambda (out)
        (put-bytevector out (parsed:file-header file))
        (for-each
          (lambda (h)
            (put-hunk out (parsed:hunk-old-start h) (parsed:hunk-old-count h) (parsed:hunk-new-start h)
                      (parsed:hunk-new-count h) (parsed:hunk-tail h) (vector->list (parsed:hunk-lines h)) #t))
          (parsed:file-hunks file)))))

  ;; git apply looks for a hunk near its new start, and with --reverse
  ;; near its old start. The side a patch applies to is the whole file
  ;; git diffed, so it keeps git's starts; the other side holds only the
  ;; chosen hunks, so its starts move by the lines of those left out.
  (define (hunks-patch-bytes who file hunks reverse?)
    (refuse-unpatchable who file)
    (unless (and (list? hunks) (pair? hunks))
      (assertion-violation who "not a list of hunks" hunks))
    (let ([first (hunk-index who file (car hunks))])
      (let check ([hs hunks] [i first])
        (unless (null? hs)
          (unless (eqv? (hunk-index who file (car hs)) i)
            (assertion-violation who "not hunks of this file, contiguous and in order" hunks))
          (check (cdr hs) (fx+ i 1)))))
    (with-output
      (lambda (out)
        (let ([git-header? (put-header out file reverse? (fx= (length hunks) (length (parsed:file-hunks file))))]
              [offset (fx- (parsed:hunk-new-start (car hunks)) (parsed:hunk-old-start (car hunks)))])
          (for-each
            (lambda (h)
              (put-hunk out
                        (if (or git-header? (not reverse?)) (parsed:hunk-old-start h) (fx+ (parsed:hunk-old-start h) offset))
                        (parsed:hunk-old-count h)
                        (if (or git-header? reverse?) (parsed:hunk-new-start h) (fx- (parsed:hunk-new-start h) offset))
                        (parsed:hunk-new-count h) (parsed:hunk-tail h) (vector->list (parsed:hunk-lines h)) git-header?))
            hunks)))))

  (define (lines-patch-bytes who file hunk first last reverse?)
    (refuse-unpatchable who file)
    (hunk-index who file hunk)
    (let* ([lines (parsed:hunk-lines hunk)] [n (vector-length lines)])
      (unless (and (fixnum? first) (fixnum? last) (fx<= 0 first last) (fx< last n))
        (assertion-violation who "not a range of the hunk's lines" (cons first last)))
      (let* ([changes (let loop ([i (fx- n 1)] [acc '()])
                        (if (fx< i 0)
                            acc
                            (loop (fx- i 1) (if (eq? (parsed:line-kind (vector-ref lines i)) 'context) acc (cons i acc)))))]
             [chosen (filter (lambda (i) (fx<= first i last)) changes)])
        (when (null? chosen)
          (error who "no change in these lines"))
        (let ([whole? (and (fx= (length (parsed:file-hunks file)) 1) (equal? chosen changes))])
          (with-output
            (lambda (out)
              (let ([git-header? (put-header out file reverse? whole?)])
                (if whole?
                    (put-hunk out (parsed:hunk-old-start hunk) (parsed:hunk-old-count hunk) (parsed:hunk-new-start hunk)
                              (parsed:hunk-new-count hunk) (parsed:hunk-tail hunk) (vector->list lines) git-header?)
                    (let* ([kept (let loop ([i (fx- n 1)] [acc '()])
                                   (if (fx< i 0)
                                       acc
                                       (let* ([l (vector-ref lines i)] [kind (parsed:line-kind l)])
                                         (loop (fx- i 1)
                                               (cond
                                                 [(or (eq? kind 'context) (fx<= first i last)) (cons l acc)]
                                                 [(eq? kind (if reverse? 'added 'removed))
                                                  (cons (line 'context (parsed:line-bytes l) (parsed:line-no-newline? l)) acc)]
                                                 [else acc])))))]
                           [out-lines (fix-markers kept)]
                           [old-count (length (filter (lambda (l) (memq (parsed:line-kind l) '(context removed))) out-lines))]
                           [new-count (length (filter (lambda (l) (memq (parsed:line-kind l) '(context added))) out-lines))])
                      (if git-header?
                          (put-hunk out (parsed:hunk-old-start hunk) old-count 0 new-count (parsed:hunk-tail hunk) out-lines #t)
                          (let ([start (if reverse? (parsed:hunk-new-start hunk) (parsed:hunk-old-start hunk))])
                            (put-hunk out start old-count start new-count (parsed:hunk-tail hunk) out-lines #f)))))))))))))

(import %internals)

(define (parse output)
  (unless (bytevector? output)
    (assertion-violation 'diff:parse "not a bytevector" output))
  (job-result output))

(define (file? v) (parsed:file? v))

(define (file-old-path file)
  (check-file 'diff:file-old-path file)
  (parsed:file-old-path file))

(define (file-new-path file)
  (check-file 'diff:file-new-path file)
  (parsed:file-new-path file))

(define (file-path file)
  (check-file 'diff:file-path file)
  (parsed:file-path file))

(define (file-old-path-bytes file)
  (check-file 'diff:file-old-path-bytes file)
  (parsed:file-old-path-bytes file))

(define (file-path-bytes file)
  (check-file 'diff:file-path-bytes file)
  (parsed:file-path-bytes file))

(define (file-status file)
  (check-file 'diff:file-status file)
  (parsed:file-status file))

(define (file-combined? file)
  (check-file 'diff:file-combined? file)
  (parsed:file-combined? file))

(define (file-old-mode file)
  (check-file 'diff:file-old-mode file)
  (parsed:file-old-mode file))

(define (file-new-mode file)
  (check-file 'diff:file-new-mode file)
  (parsed:file-new-mode file))

(define (file-old-blob file)
  (check-file 'diff:file-old-blob file)
  (parsed:file-old-blob file))

(define (file-new-blob file)
  (check-file 'diff:file-new-blob file)
  (parsed:file-new-blob file))

(define (file-binary? file)
  (check-file 'diff:file-binary? file)
  (parsed:file-binary? file))

(define (file-header file)
  (check-file 'diff:file-header file)
  (parsed:file-header file))

(define (file-hunks file)
  (check-file 'diff:file-hunks file)
  (parsed:file-hunks file))

(define (hunk? v) (parsed:hunk? v))

(define (hunk-old-start hunk)
  (check-hunk 'diff:hunk-old-start hunk)
  (parsed:hunk-old-start hunk))

(define (hunk-old-count hunk)
  (check-hunk 'diff:hunk-old-count hunk)
  (parsed:hunk-old-count hunk))

(define (hunk-new-start hunk)
  (check-hunk 'diff:hunk-new-start hunk)
  (parsed:hunk-new-start hunk))

(define (hunk-new-count hunk)
  (check-hunk 'diff:hunk-new-count hunk)
  (parsed:hunk-new-count hunk))

(define (hunk-heading hunk)
  (check-hunk 'diff:hunk-heading hunk)
  (parsed:hunk-heading hunk))

(define (hunk-lines hunk)
  (check-hunk 'diff:hunk-lines hunk)
  (parsed:hunk-lines hunk))

(define (line? v) (parsed:line? v))

(define (line-kind line)
  (check-line 'diff:line-kind line)
  (parsed:line-kind line))

(define (line-prefix line)
  (check-line 'diff:line-prefix line)
  (parsed:line-prefix line))

(define (line-bytes line)
  (check-line 'diff:line-bytes line)
  (parsed:line-bytes line))

(define (line-no-newline? line)
  (check-line 'diff:line-no-newline? line)
  (parsed:line-no-newline? line))

;; A combined line is in the result when no column removes it, and in
;; the first parent when its first column does not add it.
(define (line-numbers hunk index)
  (define (in-old? l) (not (fx= (bytevector-u8-ref (parsed:line-prefix l) 0) 43)))
  (define (in-new? l)
    (let ([p (parsed:line-prefix l)])
      (let loop ([i 0])
        (or (fx= i (bytevector-length p)) (and (not (fx= (bytevector-u8-ref p i) 45)) (loop (fx+ i 1)))))))
  (check-hunk 'diff:line-numbers hunk)
  (let ([lines (parsed:hunk-lines hunk)])
    (unless (and (fixnum? index) (fx< -1 index (vector-length lines)))
      (assertion-violation 'diff:line-numbers "not the index of a line of the hunk" index))
    (let loop ([i 0] [old (parsed:hunk-old-start hunk)] [new (parsed:hunk-new-start hunk)])
      (let ([l (vector-ref lines i)])
        (if (fx= i index)
            (values (and (in-old? l) old) (and (in-new? l) new))
            (loop (fx+ i 1) (if (in-old? l) (+ old 1) old) (if (in-new? l) (+ new 1) new)))))))

(define (file-line-counts file)
  (define (marked? l byte)
    (let ([p (parsed:line-prefix l)])
      (let loop ([i 0])
        (and (fx< i (bytevector-length p)) (or (fx= (bytevector-u8-ref p i) byte) (loop (fx+ i 1)))))))
  (check-file 'diff:file-line-counts file)
  (let loop ([hunks (parsed:file-hunks file)] [added 0] [removed 0])
    (if (null? hunks)
        (values added removed)
        (let ([lines (parsed:hunk-lines (car hunks))])
          (let each ([i 0] [added added] [removed removed])
            (if (fx= i (vector-length lines))
                (loop (cdr hunks) added removed)
                (let ([l (vector-ref lines i)])
                  (each (fx+ i 1) (if (marked? l 43) (fx+ added 1) added) (if (marked? l 45) (fx+ removed 1) removed)))))))))

(define (file-patch file)
  (check-file 'diff:file-patch file)
  (file-patch-bytes 'diff:file-patch file))

(define (hunks-patch file hunks)
  (check-file 'diff:hunks-patch file)
  (hunks-patch-bytes 'diff:hunks-patch file hunks #f))

(define (reverse-hunks-patch file hunks)
  (check-file 'diff:reverse-hunks-patch file)
  (hunks-patch-bytes 'diff:reverse-hunks-patch file hunks #t))

(define (lines-patch file hunk first last)
  (check-file 'diff:lines-patch file)
  (check-hunk 'diff:lines-patch hunk)
  (lines-patch-bytes 'diff:lines-patch file hunk first last #f))

(define (reverse-lines-patch file hunk first last)
  (check-file 'diff:reverse-lines-patch file)
  (check-hunk 'diff:reverse-lines-patch hunk)
  (lines-patch-bytes 'diff:reverse-lines-patch file hunk first last #t))

(on-unload stop-waiting!)
