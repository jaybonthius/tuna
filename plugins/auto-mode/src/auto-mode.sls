#!tuna
(import (buffers) (document) (files) (languages) (modes) (commands) (hooks) (options) (tables))

(hooks:define-hook choosers
  "Called with a buffer and a name; each entry returns a major mode or #f, and auto-mode:choose takes the first mode returned.")

(tables:define-table file-names
  "Maps a file name, what follows a dot in one, or a glob, to a major mode, or to a procedure of a buffer and a name that returns a major mode or #f. The user's table: a language plugin states its names in languages:file-names.")

(tables:define-table interpreters
  "Maps a program named on a #! line to a major mode. The user's table: a language plugin states its programs in languages:interpreters.")

(options:define-option default-mode modes:fundamental symbol?
  "The major mode auto-mode:choose returns when no chooser gives one.")

(module %internals (check-buffer interpreter without-version without-tilde file-name-keys glob? glob-match-length)

  (define (check-buffer who b)
    (unless (buffers:buffer? b)
      (assertion-violation who "not a buffer" b)))

  (define (blank? c) (or (char=? c #\space) (char=? c #\tab)))

  (define (words s)
    (let loop ([i (fx- (string-length s) 1)] [end #f] [acc '()])
      (cond
        [(fx< i 0) (if end (cons (substring s 0 end) acc) acc)]
        [(blank? (string-ref s i))
         (loop (fx- i 1) #f (if end (cons (substring s (fx+ i 1) end) acc) acc))]
        [else (loop (fx- i 1) (or end (fx+ i 1)) acc)])))

  (define (after-last c s)
    (let loop ([i (fx- (string-length s) 1)])
      (cond
        [(fx< i 0) s]
        [(char=? (string-ref s i) c) (substring s (fx+ i 1) (string-length s))]
        [else (loop (fx- i 1))])))

  (define (string-index c s)
    (let ([n (string-length s)])
      (let loop ([i 0])
        (cond
          [(fx= i n) #f]
          [(char=? (string-ref s i) c) i]
          [else (loop (fx+ i 1))]))))

  ;; The opening of the buffer's root comes first and gives no character,
  ;; so 257 tokens hold 256 characters.
  (define (first-line doc)
    (let* ([s (document:text doc 0 (fxmin 257 (document:length doc)))]
           [end (string-index #\newline s)])
      (if end (substring s 0 end) s)))

  (define (interpreter doc)
    (let ([line (first-line doc)])
      (and (fx>= (string-length line) 2)
           (char=? (string-ref line 0) #\#) (char=? (string-ref line 1) #\!)
           (let ([ws (words (substring line 2 (string-length line)))])
             (and (pair? ws)
                  (let ([program (after-last #\/ (car ws))])
                    (if (string=? program "env")
                        (find (lambda (w) (not (or (char=? (string-ref w 0) #\-) (string-index #\= w))))
                              (cdr ws))
                        program)))))))

  (define (without-version program)
    (let loop ([i (string-length program)])
      (if (and (fx> i 0) (let ([c (string-ref program (fx- i 1))]) (or (char-numeric? c) (char=? c #\.))))
          (loop (fx- i 1))
          (substring program 0 (if (and (fx> i 0) (char=? (string-ref program (fx- i 1)) #\-)) (fx- i 1) i)))))

  (define (without-tilde name)
    (let ([n (string-length name)])
      (if (and (fx> n 0) (char=? (string-ref name (fx- n 1)) #\~))
          (substring name 0 (fx- n 1))
          name)))

  (define (suffixes base)
    (let ([n (string-length base)])
      (let loop ([i 0] [acc (list base)])
        (cond
          [(fx= i n) (reverse acc)]
          [(char=? (string-ref base i) #\.) (loop (fx+ i 1) (cons (substring base (fx+ i 1) n) acc))]
          [else (loop (fx+ i 1) acc)]))))

  (define (file-name-keys name)
    (let* ([base (after-last #\/ name)] [lower (string-downcase base)])
      (if (string=? lower base)
          (suffixes base)
          (append (suffixes base) (suffixes lower)))))

  (define (glob? pattern)
    (exists (lambda (c) (memv c '(#\* #\? #\/))) (string->list pattern)))

  (define (part-matches? glob text)
    (let ([g (string-length glob)] [n (string-length text)])
      (let loop ([i 0] [j 0] [star #f] [star-j 0])
        (cond
          [(fx= i g)
           (or (fx= j n)
               (and star (fx< star-j n) (loop (fx+ star 1) (fx+ star-j 1) star (fx+ star-j 1))))]
          [(char=? (string-ref glob i) #\*) (loop (fx+ i 1) j i j)]
          [(and (fx< j n) (or (char=? (string-ref glob i) #\?) (char=? (string-ref glob i) (string-ref text j))))
           (loop (fx+ i 1) (fx+ j 1) star star-j)]
          [(and star (fx< star-j n)) (loop (fx+ star 1) (fx+ star-j 1) star (fx+ star-j 1))]
          [else #f]))))

  (define (split-parts s)
    (let loop ([i (fx- (string-length s) 1)] [end (string-length s)] [acc '()])
      (cond
        [(fx< i 0) (cons (substring s 0 end) acc)]
        [(char=? (string-ref s i) #\/) (loop (fx- i 1) i (cons (substring s (fx+ i 1) end) acc))]
        [else (loop (fx- i 1) end acc)])))

  (define (glob-match-length glob name)
    (let* ([globs (split-parts glob)] [names (split-parts name)] [k (length globs)] [n (length names)])
      (and (fx<= k n)
           (for-all part-matches? globs (list-tail names (fx- n k)))
           (fold-left (lambda (count c) (if (memv c '(#\* #\?)) count (fx+ count 1))) 0 (string->list glob))))))

(import %internals)

(define (%language-mode language) (and language (tables:ref languages:mode language #f)))

(define (%language-entries table read)
  (filter (lambda (entry) (pair? (cdr entry)))
          (map (lambda (entry) (cons (car entry) (if (%language-mode (car entry)) (read (car entry)) '())))
               (tables:entries table))))

(define (%language-with entries name)
  (exists (lambda (entry) (and (member name (cdr entry)) (car entry))) entries))

(define (by-interpreter buffer name)
  (check-buffer 'auto-mode:by-interpreter buffer)
  (unless (string? name)
    (assertion-violation 'auto-mode:by-interpreter "not a string" name))
  (let ([program (interpreter (buffers:document buffer))])
    (and program
         (let ([programs (let ([plain (without-version program)])
                           (if (string=? plain program) (list program) (list program plain)))])
           (or (exists (lambda (p) (tables:ref interpreters p #f)) programs)
               (let ([entries (%language-entries languages:interpreters languages:interpreters-of)])
                 (%language-mode (exists (lambda (p) (%language-with entries p)) programs))))))))

(define (%best-glob patterns name)
  (let loop ([patterns patterns] [best #f] [best-length -1])
    (if (null? patterns)
        best
        (let ([count (and (string? (caar patterns)) (glob? (caar patterns)) (glob-match-length (caar patterns) name))])
          (if (and count (fx> count best-length))
              (loop (cdr patterns) (car patterns) count)
              (loop (cdr patterns) best best-length))))))

(define (%user-entry name)
  (or (exists (lambda (key) (tables:ref file-names key #f)) (file-name-keys name))
      (let ([glob (%best-glob (tables:entries file-names) name)]) (and glob (cdr glob)))))

(define (%language-file-name name)
  (let ([entries (%language-entries languages:file-names languages:file-names-of)])
    (%language-mode
      (or (exists (lambda (key) (%language-with entries key)) (file-name-keys name))
          (let ([glob (%best-glob (apply append (map (lambda (entry) (map (lambda (p) (cons p (car entry))) (cdr entry)))
                                                     entries))
                                  name)])
            (and glob (cdr glob)))))))

(define (by-file-name buffer name)
  (check-buffer 'auto-mode:by-file-name buffer)
  (unless (string? name)
    (assertion-violation 'auto-mode:by-file-name "not a string" name))
  (let* ([name (without-tilde name)] [found (%user-entry name)])
    (cond
      [(procedure? found) (found buffer name)]
      [found]
      [else (%language-file-name name)])))

(define choose
  (case-lambda
    [(buffer)
     (check-buffer 'auto-mode:choose buffer)
     (choose buffer (or (files:path buffer) (buffers:name buffer)))]
    [(buffer name)
     (check-buffer 'auto-mode:choose buffer)
     (unless (string? name)
       (assertion-violation 'auto-mode:choose "not a string" name))
     (buffers:with-buffer buffer
       (or (exists (lambda (entry) (entry buffer name)) (hooks:entries choosers))
           (default-mode)))]))

(commands:define-command (normal-mode [buffer (buffers:current)])
  "Sets BUFFER's major mode to the one auto-mode:choose gives, or runs its delayed mode hooks when it has that mode already."
  (check-buffer 'auto-mode:normal-mode buffer)
  (let ([mode (choose buffer)])
    (if (and (eq? mode (modes:major-mode buffer)) (modes:hooks-delayed? buffer))
        (modes:run-delayed-hooks buffer)
        (modes:set-major-mode mode buffer))))

(define (normal-mode-delaying-hooks buffer)
  (check-buffer 'auto-mode:normal-mode-delaying-hooks buffer)
  (modes:set-major-mode-delaying-hooks (choose buffer) buffer))

(hooks:add! choosers by-interpreter -10)
(hooks:add! choosers by-file-name)
(hooks:add! files:after-visit normal-mode -50)
(hooks:add! files:after-temporary-visit normal-mode-delaying-hooks -50)
