#!tuna
(import (completion) (minibuffer) (files) (jobs) (ask) (layout) (commands) (keys))

(define-saved file-name-history '() (lambda (v) (and (list? v) (for-all string? v))))

(define (%home) (or (getenv "HOME") "/"))

(define (%expand path)
  (let ([n (string-length path)])
    (if (and (fx> n 0) (char=? (string-ref path 0) #\~) (or (fx= n 1) (char=? (string-ref path 1) #\/)))
        (string-append (%home) (substring path 1 n))
        path)))

(define (%abbreviate path)
  (let ([home (%home)])
    (let ([n (string-length home)])
      (if (and (fx> n 1) (fx>= (string-length path) n) (string=? (substring path 0 n) home)
               (or (fx= (string-length path) n) (char=? (string-ref path n) #\/)))
          (string-append "~" (substring path n (string-length path)))
          path))))

(define (%after-last-slash input)
  (let loop ([i (string-length input)])
    (cond
      [(fx= i 0) 0]
      [(char=? (string-ref input (fx- i 1)) #\/) i]
      [else (loop (fx- i 1))])))

(define (%names-folder? input)
  (let ([n (string-length input)])
    (and (fx> n 0) (char=? (string-ref input (fx- n 1)) #\/) (file-directory? (%expand input)))))

(jobs:define-worker (%list-directory places emit receive)
  (import (completion matcher))
  (let ([home (car places)] [start (cdr places)])
    (define (expand prefix)
      (cond
        [(and (fx> (string-length prefix) 0) (char=? (string-ref prefix 0) #\~))
         (string-append home (substring prefix 1 (string-length prefix)))]
        [(and (fx> (string-length prefix) 0) (char=? (string-ref prefix 0) #\/)) prefix]
        [else (string-append start prefix)]))
    (define (directory? path) (guard (c [#t #f]) (file-directory? path)))
    (define (names dir) (guard (c [#t '()]) (list-sort string<? (directory-list (if (string=? dir "") "." dir)))))
    (define (entries dir shown)
      (map (lambda (name)
             (let ([path (string-append dir name)])
               (if (directory? path)
                   (cons (string-append shown name "/") (string-append path "/"))
                   (cons (string-append shown name) path))))
           (names dir)))
    (define (base-length prefix)
      (let loop ([i (fx- (string-length prefix) 1)])
        (cond
          [(fx< i 0) 0]
          [(and (char=? (string-ref prefix i) #\/) (directory? (expand (substring prefix 0 (fx+ i 1))))) (fx+ i 1)]
          [else (loop (fx- i 1))])))
    (define (components text)
      (let loop ([cs (string->list text)] [part '()] [acc '()])
        (cond
          [(null? cs) (reverse (if (null? part) acc (cons (list->string (reverse part)) acc)))]
          [(char=? (car cs) #\/) (loop (cdr cs) '() (if (null? part) acc (cons (list->string (reverse part)) acc)))]
          [else (loop (cdr cs) (cons (car cs) part) acc)])))
    (define (expansions n prefix)
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
        (list (cons (expand (substring prefix 0 n)) ""))
        (components (substring prefix n (string-length prefix)))))
    (let loop ([prefix (receive)])
      (emit 'clear)
      (if (or (string=? prefix "") (directory? (expand prefix)))
          (emit (list->vector (entries (expand prefix) "")))
          (let ([n (base-length prefix)])
            (emit (list 'base n))
            (emit (list->vector (apply append (map (lambda (dir) (entries (car dir) (cdr dir))) (expansions n prefix)))))))
      (loop (receive)))))

(define read-file-name
  (case-lambda
    [(question) (read-file-name question (files:directory) file-name-history)]
    [(question directory) (read-file-name question directory file-name-history)]
    [(question directory h)
     (unless (string? directory)
       (assertion-violation 'file-picker:read-file-name "not a string" directory))
     (let* ([dir (%expand directory)]
            [dir (if (and (fx> (string-length dir) 0) (char=? (string-ref dir (fx- (string-length dir) 1)) #\/))
                     dir
                     (string-append dir "/"))])
       (%expand
         (minibuffer:call-with-setup
           (lambda (p) (minibuffer:set-input! p (%abbreviate dir)))
           (lambda ()
             (completion:read-or-input question
               (list (completion:source
                       (job %list-directory (cons (%home) dir))
                       (split %after-last-slash)
                       (category completion:file-category)))
               h)))))]))

(commands:define-command (find-file [path (ask:file-name "Find file: ")])
  "Visits PATH and shows its buffer in the selected view."
  (layout:switch-to-buffer (files:visit path)))

(set-option! ask:file-name-reader read-file-name)
;; A candidate under a folder part that does not exist carries that
;; part, such as c/t/m's code/tuna/main.sls, which only partial matches.
(table-set! completion:category-styles completion:file-category (list completion:partial))
(table-set! completion:category-prefers-input completion:file-category %names-folder?)
(keys:bind! keys:global "C-x C-f" find-file)
