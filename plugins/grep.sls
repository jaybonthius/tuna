#!tuna
(import (completion) (commands) (editing) (files) (keys) (layout) (processes) (projects) (views))

(define-option command-line
  (list "rg" "--null" "--line-buffered" "--color=never" "--max-columns=1000" "--path-separator" "/"
        "--smart-case" "--no-heading" "--with-filename" "--line-number" "--column" "--search-zip")
  (lambda (v) (and (pair? v) (list? v) (for-all string? v)))
  "The program grep:grep runs, then the arguments it starts with.")

(define-option min-input 3 (lambda (v) (and (fixnum? v) (fx>= v 0)))
  "How many characters the search must hold before grep:grep runs a search.")

(define-option delay 0.2 (lambda (v) (and (real? v) (>= v 0)))
  "Seconds without typing before grep:grep runs a search.")

(define (%split input)
  (let loop ([i 0])
    (cond
      [(fx= i (string-length input)) i]
      [(char=? (string-ref input i) #\#) (fx+ i 1)]
      [else (loop (fx+ i 1))])))

(define (%search-of prefix)
  (let ([n (string-length prefix)])
    (if (and (fx> n 0) (char=? (string-ref prefix (fx- n 1)) #\#)) (substring prefix 0 (fx- n 1)) prefix)))

(define (%option? component) (char=? (string-ref component 0) #\-))

(define (%word component)
  (if (and (fx> (string-length component) 1) (char=? (string-ref component 0) #\\)
           (char=? (string-ref component 1) #\-))
      (substring component 1 (string-length component))
      component))

(define (%words-and-options search)
  (let loop ([cs (completion:components search)] [words '()])
    (cond
      [(null? cs) (values (reverse words) '())]
      [(%option? (car cs))
       (let options ([cs cs] [acc '()])
         (cond
           [(null? cs) (values (reverse words) (reverse acc))]
           [(string=? (car cs) "--") (values (append (reverse words) (cdr cs)) (reverse acc))]
           [else (options (cdr cs) (cons (car cs) acc))]))]
      [else (loop (cdr cs) (cons (%word (car cs)) words))])))

;; Words match a line in any order only through look-ahead, which rg's
;; default regular expression engine lacks, and which a fixed string
;; cannot hold.
(define (%pattern-arguments words fixed?)
  (cond
    [(null? (cdr words)) (list "-e" (car words))]
    [fixed?
     (list "-e" (apply string-append (car words) (map (lambda (word) (string-append " " word)) (cdr words))))]
    [else
     (list "--engine=auto" "-e"
           (apply string-append "^" (map (lambda (word) (string-append "(?=.*" word ")")) words)))]))

;; Without a path, rg searches its standard input, which is a pipe.
(define (%arguments first-arguments search)
  (let-values ([(words options) (%words-and-options search)])
    (and (pair? words)
         (let ([fixed? (exists (lambda (argument) (member argument '("-F" "--fixed-strings")))
                               (append first-arguments options))])
           (append first-arguments (%pattern-arguments words fixed?) options (list "."))))))

(define (%same-file? line end file)
  (and (fx= (string-length file) end)
       (let loop ([i 0])
         (or (fx= i end) (and (char=? (string-ref line i) (string-ref file i)) (loop (fx+ i 1)))))))

;; rg names each file by the path it was given, so a name under "." starts
;; with "./". It prints a file's lines together, so they share one path
;; string: a search can find millions of lines.
(define (%line-parser directory column?)
  (let ([file ""] [path #f])
    (define (path-of! line end start)
      (unless (%same-file? line end file)
        (set! file (substring line 0 end))
        (set! path (if (char=? (string-ref file 0) #\/)
                       file
                       (string-append directory (substring file start end)))))
      path)
    (define (number-end line j n)
      (let loop ([j j] [number 0])
        (if (fx= j n)
            (values #f #f)
            (let ([c (string-ref line j)])
              (if (char<=? #\0 c #\9)
                  (loop (fx+ j 1) (+ (* number 10) (fx- (char->integer c) (char->integer #\0))))
                  (values j number))))))
    (lambda (line)
      (let ([n (string-length line)])
        (let find-path-end ([i 0])
          (cond
            [(fx= i n) #f]
            [(char=? (string-ref line i) #\nul)
             (let-values ([(j number) (number-end line (fx+ i 1) n)])
               (and j (fx> i 0) (fx> j (fx+ i 1))
                    (let ([c (string-ref line j)])
                      (and (memv c '(#\: #\-))
                           (let*-values ([(start) (if (and (fx>= i 2) (char=? (string-ref line 0) #\.)
                                                           (char=? (string-ref line 1) #\/))
                                                      2
                                                      0)]
                                         [(column-end column) (if (and column? (char=? c #\:))
                                                                  (number-end line (fx+ j 1) n)
                                                                  (values #f #f))]
                                         [(k byte-column) (if (and column-end (fx> column-end (fx+ j 1))
                                                                   (char=? (string-ref line column-end) #\:))
                                                              (values column-end column)
                                                              (values j #f))])
                             (let ([text (if (fx= k j)
                                             (substring line start n)
                                             (let* ([head (fx- j start)] [t (make-string (fx+ head (fx- n k)))])
                                               (string-copy! line start t 0 head)
                                               (string-copy! line k t head (fx- n k))
                                               t))])
                               (string-set! text (fx- i start) c)
                               (string-set! text (fx- j start) c)
                               (cons text
                                     (cons* (path-of! line i start) number
                                            (if byte-column (%character-column line (fx+ k 1) byte-column) 0)))))))))]
            [else (find-path-end (fx+ i 1))]))))))

;; rg counts a column in bytes from 1. A line rg leaves out as too long
;; still has its column, so bytes past the text it printed count one
;; character each.
(define (%character-column line start byte-column)
  (let ([n (string-length line)])
    (let loop ([i start] [bytes (fx- byte-column 1)] [column 0])
      (cond
        [(fx<= bytes 0) column]
        [(fx= i n) (fx+ column bytes)]
        [else
         (let ([code (char->integer (string-ref line i))])
           (loop (fx+ i 1)
                 (fx- bytes (cond [(fx< code #x80) 1] [(fx< code #x800) 2] [(fx< code #x10000) 3] [else 4]))
                 (fx+ column 1)))]))))

(define (%search-source directory)
  (lambda (emit)
    (let ([search #f] [timer #f] [running #f])
      (define (stop!)
        (when timer
          (cancel-timer! timer)
          (set! timer #f))
        (when running
          (processes:stop! running)
          (set! running #f)))
      (define (run! command minimum)
        (let ([arguments (and (fx>= (string-length search) minimum) (%arguments (cdr command) search))])
          (cond
            [arguments
             (let* ([found '()] [cleared? #f] [process #f] [parse (%line-parser directory (and (member "--column" (cdr command)) #t))]
                    [receive-line! (processes:line-receiver 0
                                     (lambda (line end)
                                       (unless (eof-object? line)
                                         (let ([c (parse line)])
                                           (when c (set! found (cons c found)))))))])
               ;; The lines found before stay until the new search shows
               ;; its own, so the list does not flash empty at each key.
               (define (clear!)
                 (unless cleared?
                   (set! cleared? #t)
                   (emit 'clear)))
               (set! process
                 (processes:start (car command) arguments
                   (lambda (bytes end)
                     (receive-line! bytes end)
                     (unless (null? found)
                       (clear!)
                       (emit (list->vector (reverse found)))
                       (set! found '())))
                   (lambda (status)
                     (when (eq? process running)
                       (set! running #f)
                       (when (fixnum? status) (processes:report-error-output process 'grep:grep))
                       (clear!)
                       (emit 'done)))
                   (processes:options [directory directory] [separate-stderr #t])))
               (set! running process)
               (processes:close-input! process))]
            [else
             (emit 'clear)
             (emit 'done)])))
      (lambda (prefix)
        (cond
          [(eof-object? prefix) (stop!)]
          [(equal? (%search-of prefix) search)
           (unless (or timer running) (emit 'done))]
          [else
           (stop!)
           (set! search (%search-of prefix))
           (let ([command (command-line)] [minimum (min-input)])
             (set! timer
               (as-module (this-module)
                 (run-with-timer (delay)
                   (lambda ()
                     (set! timer #f)
                     (run! command minimum))))))])))))

(define (%search-folder)
  (let ([folder (files:directory)])
    (cond
      [(projects:find folder) => projects:root]
      [else folder])))

(define (%path-length text path folder)
  (if (char=? (string-ref text 0) #\/) (string-length path) (fx- (string-length path) (string-length folder))))

;; A file's lines share one path string, so the title is cut from the
;; first of them only.
(define (%file-title folder)
  (let ([path #f] [title #f])
    (lambda (text location)
      (unless (eq? (car location) path)
        (set! path (car location))
        (set! title (substring text 0 (%path-length text path folder))))
      title)))

(define (%line-row folder)
  (lambda (text location)
    (substring text (fx+ (%path-length text (car location) folder) 1) (string-length text))))

(define (%read-location)
  (let ([folder (%search-folder)])
    (completion:read "Grep: "
      (list (completion:source
              (stream (%search-source folder))
              (split %split)
              (in-order)
              (group (%file-title folder) (%line-row folder))
              (category completion:location-category))))))

(commands:define-command (grep [location (%read-location)])
  "Visits LOCATION, a line found by rg in the files of the current buffer's project, else under its directory, at its match."
  (let ([b (files:visit (car location))])
    (layout:switch-to-buffer b)
    (views:set-point! (layout:selected-view) (editing:line-position b (cadr location) (cddr location)))))

(keys:bind! keys:global "M-s r" grep)
