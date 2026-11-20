(library (file-picker folders)
  (export discarded-length restarted-name expand-path directory? folder-entries prefix-base-length partial-expansions)
  (import (chezscheme) (completion matcher))

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

  (define (folder-entries dir shown)
    (map (lambda (name)
           (let ([path (string-append dir name)])
             (if (directory? path)
                 (cons (string-append shown name "/") (string-append path "/"))
                 (cons (string-append shown name) path))))
         (names dir)))

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
