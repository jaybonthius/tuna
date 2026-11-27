(library (kernel-test)
  (export run-in-kernel write-module! test-folder sleep-ms as-test-owner delete-test-folder!)
  (import (except (chezscheme) exit) (lang loader) (tuna core kernel) (tuna core modules))

  ;; Modules a test writes are found in its own folder, and Tuna's
  ;; default plugins in the checkout's.
  (define test-folder
    (let ([folder (format "/tmp/tuna-kernel-test-~a" (get-process-id))])
      (mkdir folder)
      (mkdir (string-append folder "/lib"))
      folder))

  (define (write-module! name text)
    (let ([path (string-append test-folder "/lib/" name ".sls")])
      (let make ([dir (path-parent path)])
        (unless (file-directory? dir) (make (path-parent dir)) (mkdir dir)))
      (when (file-exists? path) (delete-file path))
      (call-with-output-file path (lambda (p) (put-string p text)))))

  (define (sleep-ms ms)
    (sleep (make-time 'time-duration (* (mod ms 1000) 1000000) (quotient ms 1000))))

  (define (delete-test-folder!) (delete-tree test-folder))

  (define (delete-tree path)
    (cond
      [(file-directory? path #f)
       (for-each (lambda (entry) (delete-tree (string-append path "/" entry))) (directory-list path))
       (delete-directory path)]
      [(file-exists? path #f) (delete-file path)]))

  ;; A test changes things only as an owner of its own, since the kernel
  ;; makes no change itself.
  (define as-test-owner
    (let ([owner #f])
      (lambda (thunk)
        (unless (and owner (owner-live? owner)) (set! owner (make-owner '(test))))
        (call-as-owner owner thunk))))

  ;; The tests run in a task on the main loop, as plugins' code does; the
  ;; test's exit ends the process.
  (define (run-in-kernel thunk)
    (compile-file-message #f)
    (install-module-lookup! (library-directories)
      (append
        (list (cons (string-append test-folder "/lib") (string-append test-folder "/obj")))
        (map (lambda (name)
               (cons (format "plugins/~a/src" name) (format "~a/plugins-obj/~a" test-folder name)))
             (sort string<? (directory-list "plugins")))
        (list (cons "start/src" (string-append test-folder "/start-obj")))))
    (install-loader!)
    (start-top-level!)
    (install-exit-runner!)
    (spawn-kernel-task (lambda (restore) (thunk)))
    (run-main-loop)))
