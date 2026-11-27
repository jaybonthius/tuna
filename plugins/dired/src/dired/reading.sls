(library (dired reading)
  (export resolve-folder resolved-path resolved-modified
          read-folder folder-read-attributes folder-read-space folder-read-entries
          listed-name listed-attributes listed-broken?
          non-empty-folders failure? failure-message failure-irritants failure-format?)
  (import (chezscheme) (files attributes) (files paths))

  ;; What a job sends back is plain data, so each result is a vector, read
  ;; through the accessors below.
  (define (resolved-path r) (vector-ref r 0))
  (define (resolved-modified r) (vector-ref r 1))
  (define (folder-read-attributes r) (vector-ref r 0))
  (define (folder-read-space r) (vector-ref r 1))
  (define (folder-read-entries r) (vector-ref r 2))
  (define (listed-name e) (vector-ref e 0))
  (define (listed-attributes e) (vector-ref e 1))
  (define (listed-broken? e) (vector-ref e 2))
  (define (failure? v) (and (vector? v) (fx= (vector-length v) 4) (eq? (vector-ref v 0) 'failed)))
  (define (failure-message f) (vector-ref f 1))
  (define (failure-irritants f) (vector-ref f 2))
  (define (failure-format? f) (vector-ref f 3))

  ;; A job's raise would go to report as well as to the task waiting for
  ;; it, so a worker hands back its failure as data. The main thread
  ;; formats the message, so that it names paths as the listing's
  ;; questions do; it is marked a format only when it formats with the
  ;; irritants as sent, so formatting there cannot fail.
  (define (failing thunk)
    (define (plain x) (if (or (string? x) (symbol? x) (number? x)) x (format "~s" x)))
    (guard (c [#t (let ([message (if (message-condition? c) (condition-message c) "failed")]
                        [irritants (if (and (irritants-condition? c) (list? (condition-irritants c)))
                                       (map plain (condition-irritants c))
                                       '())])
                    (vector 'failed message irritants
                            (and (format-condition? c) (guard (e [#t #f]) (apply format message irritants) #t))))])
      (thunk)))

  (define (folder? a) (eq? (file-attributes-type a) (file-type folder)))

  (define (resolve-folder path)
    (failing
      (lambda ()
        (let* ([path (true-path path)] [a (read-file-attributes path)])
          (vector path (and (folder? a) (file-attributes-modified a)))))))

  ;; A name gone between the folder's read and its own is left out, as ls
  ;; leaves it out.
  (define (read-folder folder)
    (failing
      (lambda ()
        (let* ([names (make-owner-names)] [self (read-file-attributes folder names)])
          (define (entry name)
            (let ([path (string-append folder name)])
              (guard (c [(i/o-error? c) #f])
                (let ([a (read-file-attributes path names)])
                  (vector name a (and (eq? (file-attributes-type a) (file-type link)) (not (file-exists? path))))))))
          (unless (folder? self)
            (raise (condition (make-error) (make-message-condition "not a folder") (make-irritants-condition (list folder)))))
          (vector self
                  (guard (c [(i/o-error? c) #f]) (file-system-space folder))
                  (list->vector
                    (cons* (vector "." self #f)
                           (vector ".." (read-file-attributes (string-append folder "..") names) #f)
                           (filter values (map entry (directory-list folder))))))))))

  (define (non-empty-folders paths)
    (filter (lambda (path) (and (file-directory? path #f) (pair? (directory-list path)))) paths)))
