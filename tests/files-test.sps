(import (chezscheme) (tuna-test) (tuna files))

(define root
  (let ([dir (format "/tmp/tuna-files-test-~a" (get-process-id))])
    (mkdir dir)
    dir))

(test "threads making the same folders at once all succeed"
  (do ([round 0 (+ round 1)]) ((= round 50))
    (let ([folder (format "~a/~a/a/b/c" root round)] [failed 0] [m (make-mutex)])
      (for-each thread-join
        (map (lambda (i)
               (fork-thread
                 (lambda ()
                   (guard (c [#t (with-mutex m (set! failed (+ failed 1)))])
                     (make-folders! folder)))))
             (iota 8)))
      (check-equal? 0 failed)
      (check (file-directory? folder)))))

(test "a folder that cannot be made raises"
  (call-with-output-file (string-append root "/plain") (lambda (p) (display "x" p)))
  (check-raises i/o-error? (make-folders! (string-append root "/plain/sub"))))

(test "text reads as UTF-8, with invalid bytes replaced and line ends as linefeeds"
  (let ([file (string-append root "/text")])
    (call-with-port (open-file-output-port file)
      (lambda (p) (put-bytevector p (bytevector #x68 #xC3 #xA9 #xFF #x0D #x0A))))
    (check-equal? "h\xE9;\xFFFD;\n" (read-text-file file))
    (call-with-port (open-file-output-port file (file-options no-fail)) (lambda (p) (void)))
    (check-equal? "" (read-text-file file))))

(test "a path starting with ~/ is under the home folder, and no other"
  (check-equal? "/h/a/b" (expand-home "~/a/b" "/h"))
  (check-equal? "~a" (expand-home "~a" "/h"))
  (check-equal? "/x/~/a" (expand-home "/x/~/a" "/h"))
  (check-equal? "~" (expand-home "~" "/h")))

(test "string-prefix?"
  (check (string-prefix? "" "abc"))
  (check (string-prefix? "ab" "abc"))
  (check (string-prefix? "abc" "abc"))
  (check (not (string-prefix? "abcd" "abc")))
  (check (not (string-prefix? "b" "abc"))))

(system (format "rm -rf '~a'" root))
(test-exit)
