(define (check-program name)
  (unless (zero? (system (format "command -v ~a > /dev/null" name)))
    (errorf 'build "~a is missing" name)))

(for-each check-program '("make" "cmake" "cc" "pkg-config"))

(unless (file-directory? "build") (mkdir "build"))

;; H2O's own makefile builds into the folder it is given, here this
;; plugin's. This build may run under another make, whose job server it
;; must not join.
(let ([command (format "env -u MAKEFLAGS -u MAKELEVEL -u MFLAGS make -s -C ../chez-toolbelt/chez-h2o h2o H2O_BUILD='~a/build/h2o' > build/h2o.log 2>&1"
                 (current-directory))])
  (unless (zero? (system command))
    (display (call-with-input-file "build/h2o.log" get-string-all))
    (errorf 'build "the build of H2O failed")))
