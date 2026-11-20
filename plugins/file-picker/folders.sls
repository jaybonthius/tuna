(library (file-picker folders)
  (export discarded-length restarted-name expand-path directory? folder-entries prefix-base-length partial-expansions)
  (import (chezscheme) (completion matcher) (files attributes))

  (define (discarded-length name)
    (let ([n (string-length name)])
      (let loop ([i (fx- n 1)])
        (cond
          [(fx< i 1) 0]
          [(and (char=? (string-ref name (fx- i 1)) #\/)
                (let ([c (string-ref name i)])
                  (or (char=? c #\/)
                      (and (char=? c #\~) (or (fx= (fx+ i 1) n) (char=? (string-ref name (fx+ i 1)) #\/))))))
           i]
          [else (loop (fx- i 1))]))))

  (define (restarted-name name)
    (substring name (discarded-length name) (string-length name)))

  (define (expand-path home start typed)
    (define prefix (restarted-name typed))
    (cond
      [(and (fx> (string-length prefix) 0) (char=? (string-ref prefix 0) #\~))
       (string-append home (substring prefix 1 (string-length prefix)))]
      [(and (fx> (string-length prefix) 0) (char=? (string-ref prefix 0) #\/)) prefix]
      [else (string-append start prefix)]))

  (define (directory? path) (guard (c [#t #f]) (file-directory? path)))

  (define (names dir) (guard (c [#t '()]) (list-sort string<? (directory-list (if (string=? dir "") "." dir)))))

  ;; A file removed since its folder was listed, or one the user may not
  ;; read, has no attributes and so no details.
  (define (attributes path owners)
    (guard (c [(i/o-error? c) #f]) (read-file-attributes path owners)))

  ;; Reading attributes looks up each file's owner and group unless one
  ;; cache serves the listing, and in a folder of one owner that lookup
  ;; costs more than the rest of the listing. A link's type is its own,
  ;; so only a link is asked again whether it leads to a folder.
  (define (folder-entries dir shown)
    (let ([owners (make-owner-names)])
      (map (lambda (name)
             (let* ([path (string-append dir name)]
                    [a (attributes path owners)]
                    [details (and a (cons (file-attributes-size a) (file-attributes-modified a)))])
               (if (if (and a (not (eq? (file-attributes-type a) (file-type link))))
                       (eq? (file-attributes-type a) (file-type folder))
                       (directory? path))
                   (vector (string-append shown name "/") (string-append path "/") details)
                   (vector (string-append shown name) path details))))
           (names dir))))

  (define (prefix-base-length home start prefix)
    (let loop ([i (fx- (string-length prefix) 1)])
      (cond
        [(fx< i 0) 0]
        [(and (char=? (string-ref prefix i) #\/) (directory? (expand-path home start (substring prefix 0 (fx+ i 1)))))
         (fx+ i 1)]
        [else (loop (fx- i 1))])))

  (define (components text)
    (let loop ([cs (string->list text)] [part '()] [acc '()])
      (cond
        [(null? cs) (reverse (if (null? part) acc (cons (list->string (reverse part)) acc)))]
        [(char=? (car cs) #\/) (loop (cdr cs) '() (if (null? part) acc (cons (list->string (reverse part)) acc)))]
        [else (loop (cdr cs) (cons (car cs) part) acc)])))

  (define (partial-expansions home start n prefix)
    (fold-left
      (lambda (found component)
        (let ([matches? (pattern-matcher (partial-pattern component))])
          (apply append
            (map (lambda (dir)
                   (let ([path (car dir)] [shown (cdr dir)])
                     (map (lambda (name) (cons (string-append path name "/") (string-append shown name "/")))
                          (filter (lambda (name) (and (matches? name) (directory? (string-append path name))))
                                  (names path)))))
                 found))))
      (list (cons (expand-path home start (substring prefix 0 n)) ""))
      (components (substring prefix n (string-length prefix))))))
