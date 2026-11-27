(library (files paths)
  (export true-path)
  (import (chezscheme) (files system))

  (define c-realpath
    (begin
      (load-shared-object #f)
      (foreign-procedure __collect_safe "realpath" (uptr uptr) uptr)))
  (define c-free (foreign-procedure "free" (uptr) void))

  (define (realpath path)
    (call-with-c-string path
      (lambda (p)
        (let ([r (c-realpath p 0)])
          (and (not (eqv? r 0))
               (let ([s (c-string->string r)])
                 (c-free r)
                 s))))))

  (define (join folder name)
    (if (and (fx> (string-length folder) 0)
             (char=? (string-ref folder (fx- (string-length folder) 1)) #\/))
        (string-append folder name)
        (string-append folder "/" name)))

  (define (absolute path)
    (cond
      [(and (fx>= (string-length path) 1) (char=? (string-ref path 0) #\/)) path]
      [(or (string=? path "~") (and (fx>= (string-length path) 2) (string=? (substring path 0 2) "~/")))
       (string-append (or (getenv "HOME") "") (substring path 1 (string-length path)))]
      [else (join (current-directory) path)]))

  ;; A missing file's path still resolves the folders that exist, so the
  ;; first save writes where a later visit will look.
  (define (true-path path)
    (unless (string? path)
      (assertion-violation 'true-path "not a string" path))
    (let resolve ([path (absolute path)])
      (or (realpath path)
          (let ([folder (path-parent path)] [name (path-last path)])
            (if (or (string=? folder path) (string=? folder ""))
                path
                (let ([folder (resolve folder)])
                  (cond
                    [(or (string=? name "") (string=? name ".")) folder]
                    [(string=? name "..") (path-parent folder)]
                    [else (join folder name)]))))))))
