#!tuna
(import (buffers) (document) (files) (modes) (commands))

(define-hook choosers
  "Called with a buffer and a name; each entry returns a major mode or #f, and auto-mode:choose takes the first mode returned.")

(define-table file-names
  "Maps a file name, or what follows a dot in one, to a major mode, or to a procedure of a buffer and a name that returns a major mode or #f.")

(define-table interpreters
  "Maps a program named on a #! line to a major mode.")

(define-option default-mode modes:fundamental symbol?
  "The major mode auto-mode:choose returns when no chooser gives one.")

(module %internals (check-buffer interpreter without-version without-tilde file-name-keys)

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
          (append (suffixes base) (suffixes lower))))))

(import %internals)

(define (by-interpreter buffer name)
  (check-buffer 'auto-mode:by-interpreter buffer)
  (unless (string? name)
    (assertion-violation 'auto-mode:by-interpreter "not a string" name))
  (let ([program (interpreter (buffers:document buffer))])
    (and program
         (or (table-ref interpreters program #f)
             (let ([plain (without-version program)])
               (and (not (string=? plain program))
                    (table-ref interpreters plain #f)))))))

(define (by-file-name buffer name)
  (check-buffer 'auto-mode:by-file-name buffer)
  (unless (string? name)
    (assertion-violation 'auto-mode:by-file-name "not a string" name))
  (let ([name (without-tilde name)])
    (let loop ([keys (file-name-keys name)])
      (and (pair? keys)
           (let ([found (table-ref file-names (car keys) #f)])
             (cond
               [(not found) (loop (cdr keys))]
               [(procedure? found) (found buffer name)]
               [else found]))))))

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
       (or (exists (lambda (entry) (entry buffer name)) (hook-entries choosers))
           (default-mode)))]))

(commands:define-command (normal-mode [buffer (buffers:current)])
  "Sets BUFFER's major mode to the one auto-mode:choose gives."
  (check-buffer 'auto-mode:normal-mode buffer)
  (modes:set-major-mode (choose buffer) buffer))

(add-hook! choosers by-interpreter -10)
(add-hook! choosers by-file-name)
(add-hook! files:after-visit normal-mode -50)
