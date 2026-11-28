#!tuna
(import (comment-syntax) (indentation) (syntax) (editing) (buffers) (document) (views) (modes) (commands) (keys)
        (options) (tables))

(options:define-option padding " " string?
  "The text written between a comment's start and its text, and between its text and its end.")

(options:define-option empty-lines #f boolean?
  "Whether commenting lines also comments the empty ones among them.")

(define (%start who b)
  (let-values ([(start end) (comment-syntax:delimiters b)])
    (or start (error who "no comment syntax"))))

(define (%end b)
  (let-values ([(start end) (comment-syntax:delimiters b)]) end))

(define (%repeat text n) (apply string-append (map (lambda (i) text) (iota n))))

(define (%line-start-text who b)
  (let ([start (%start who b)])
    (string-append (%repeat start (fx+ 1 (if (fx= (string-length start) 1) (comment-syntax:add) 0))) (padding))))

(define (%end-text b)
  (if (string=? (%end b) "") "" (string-append (padding) (%end b))))

;; A buffer's first line starts at the opening of the node its text is
;; in, which is no text.
(define (%line-bounds b line)
  (editing:lines-bounds b (document:line-start (buffers:document b) line) #f))

(define (%line-start b line) (let-values ([(start end) (%line-bounds b line)]) start))

(define (%line-end b line) (let-values ([(start end) (%line-bounds b line)]) end))

(define (%text-start b line)
  (indentation:blanks-end (buffers:document b) (%line-start b line) (%line-end b line)))

(define (%starts-with? doc p text)
  (let ([n (string-length text)])
    (and (fx<= (fx+ p n) (document:length doc))
         (string=? text (buffers:text-between doc p (fx+ p n))))))

(define (%lexer? b) (and (syntax:lexer (modes:major-mode b)) #t))

(define (%class? lexeme class) (eq? (syntax:lexeme-class lexeme) class))

(define (%commented-line? who b line)
  (let* ([doc (buffers:document b)] [p (%text-start b line)])
    (and (%starts-with? doc p (%start who b))
         (or (not (%lexer? b))
             (let ([l (syntax:lexeme-starting-at b p)]) (and l (%class? l (syntax:class comment))))))))

(define (%has-text? b line) (fx< (%text-start b line) (%line-end b line)))

(define (%line-range first last)
  (map (lambda (k) (fx+ first k)) (iota (fx+ 1 (fx- last first)))))

(define (%lines b point mark)
  (let-values ([(start end) (editing:lines-bounds b point mark)])
    (let ([doc (buffers:document b)])
      (%line-range (document:line doc start) (document:line doc end)))))

(define (%commented? who b lines)
  (let ([doc (buffers:document b)])
    (for-all (lambda (line) (or (not (%has-text? b line)) (%commented-line? who b line))) lines)))

;; Edits made from the last line up move no position above them.
(define (%comment-lines! who b lines)
  (let* ([doc (buffers:document b)]
         [texts (filter (lambda (line) (%has-text? b line)) lines)]
         [column (if (null? texts) 0 (apply min (map (lambda (line) (indentation:column b (%text-start b line))) texts)))]
         [start (%line-start-text who b)] [end (%end-text b)])
    (for-each
      (lambda (line)
        (let ([doc (buffers:document b)])
          (cond
            [(%has-text? b line)
             (unless (string=? end "") (buffers:replace! b (%line-end b line) (%line-end b line) end))
             (let ([at (let back ([q (%text-start b line)]) (if (fx> (indentation:column b q) column) (back (fx- q 1)) q))])
               (buffers:replace! b at at start))]
            [(empty-lines)
             (let ([at (%line-start b line)])
               (buffers:replace! b at (%line-end b line) (string-append (indentation:blanks b 0 column) (%string-trim-right start))))])))
      (reverse lines))))

(define (%string-trim-right text)
  (let loop ([n (string-length text)])
    (if (and (fx> n 0) (indentation:blank? (string-ref text (fx- n 1)))) (loop (fx- n 1)) (substring text 0 n))))

(define (%uncomment-lines! who b lines)
  (let ([comment-start (%start who b)] [end (%end b)])
    (for-each
      (lambda (line)
        (when (%commented-line? who b line)
          (let* ([doc (buffers:document b)] [line-end (%line-end b line)])
            (unless (string=? end "")
              (let* ([tail (string-append (padding) end)] [from (fx- line-end (string-length tail))])
                (cond
                  [(and (fx>= from 0) (%starts-with? doc from tail)) (buffers:replace! b from line-end "")]
                  [(%starts-with? doc (fx- line-end (string-length end)) end)
                   (buffers:replace! b (fx- line-end (string-length end)) line-end "")])))
            (let* ([doc (buffers:document b)] [p (%text-start b line)]
                   [run-end (let loop ([q p]) (if (%starts-with? doc q comment-start) (loop (fx+ q (string-length comment-start))) q))]
                   [end (if (%starts-with? doc run-end (padding)) (fx+ run-end (string-length (padding))) run-end)])
              (buffers:replace! b p end "")))))
      (reverse lines))))

(define (%toggle-lines! who b lines)
  (if (%commented? who b lines)
      (%uncomment-lines! who b lines)
      (%comment-lines! who b lines)))

(define (%line-comment b line)
  (let* ([doc (buffers:document b)] [start (%line-start b line)] [end (%line-end b line)])
    (if (%lexer? b)
        (let loop ([ls (syntax:lexemes b start end)] [code? #f])
          (cond
            [(null? ls) (values #f #f code?)]
            [(and (%class? (car ls) (syntax:class comment)) (fx>= (syntax:lexeme-start (car ls)) start))
             (values (syntax:lexeme-start (car ls)) (fxmin end (syntax:lexeme-end (car ls))) code?)]
            [else (loop (cdr ls) (or code? (fx>= (syntax:lexeme-end (car ls)) start)))]))
        (let-values ([(comment-start comment-end) (comment-syntax:delimiters b)])
          (let loop ([q start])
            (cond
              [(fx>= q end) (values #f #f (%has-text? b line))]
              [(%starts-with? doc q comment-start) (values q end (fx< (%text-start b line) q))]
              [else (loop (fx+ q 1))]))))))

(define (%comment-column b line code-end)
  (let* ([doc (buffers:document b)] [code-column (indentation:column b code-end)]
         [above (and (fx> line 1)
                     (let-values ([(s e code?) (%line-comment b (fx- line 1))])
                       (and s code? (indentation:column b s))))])
    (fxmax (fx+ code-column 1)
           (if (and above (fx> above code-column)) above (comment-syntax:column)))))

(define (%after-start doc p comment-start)
  (let* ([run (let loop ([q p]) (if (%starts-with? doc q comment-start) (loop (fx+ q (string-length comment-start))) q))])
    (indentation:blanks-end doc run (fx- (document:length doc) 1))))

(define (%dwim-at! who view c p m)
  (let* ([b (views:buffer view)] [doc (buffers:document b)] [line (document:line doc p)])
    (cond
      [(and m (not (fx= m p))) (%toggle-lines! who b (%lines b p m))]
      [(not (%has-text? b line))
       (let ([start (%line-start b line)] [text (%line-start-text who b)] [end (%end-text b)])
         (buffers:replace! b start (%line-end b line) (string-append text end))
         (indentation:line! b start)
         (let ([doc (buffers:document b)])
           (editing:place-cursor! view c (fx- (%line-end b (document:line doc start)) (string-length end)) #f)))]
      [else
       (let-values ([(s e code?) (%line-comment b line)])
         (cond
           [(and s (not code?))
            (indentation:line! b (%line-start b line))
            (let* ([doc (buffers:document b)] [s (%text-start b line)])
              (editing:place-cursor! view c (%after-start doc s (%start who b)) #f))]
           [s
            (let* ([code-end (indentation:blanks-start doc 0 s)] [column (%comment-column b line code-end)]
                   [blanks (indentation:blanks b (indentation:column b code-end) column)])
              (buffers:replace! b code-end s blanks)
              (let ([doc (buffers:document b)])
                (editing:place-cursor! view c (%after-start doc (fx+ code-end (string-length blanks)) (%start who b)) #f)))]
           [else
            (let* ([code-end (indentation:blanks-start doc 0 (%line-end b line))] [column (%comment-column b line code-end)]
                   [text (string-append (indentation:blanks b (indentation:column b code-end) column) (%start who b))])
              (buffers:replace! b code-end (%line-end b line) (string-append text (%end-text b)))
              (editing:place-cursor! view c (fx+ code-end (string-length text)) #f))]))])))

(commands:define-command (dwim [prefix (commands:prefix-argument)])
  "Comments or uncomments each cursor's region; on a line of blanks starts a comment; on a line with code moves its comment, or starts one, at the comment column; with a prefix argument kills the line's comment, or those of as many lines as a numeric prefix says."
  (let* ([view (views:command-view 'comment:dwim)] [c (car (views:cursors view))])
    (%start 'comment:dwim (views:buffer view))
    (if (and prefix (not (and (views:cursor-mark c) (not (fx= (views:cursor-mark c) (views:cursor-point c))))))
        (kill (if (integer? prefix) prefix 1))
        (editing:for-each-cursor view (lambda (c p m) (%dwim-at! 'comment:dwim view c p m))))))

(define (%after-lines b last)
  (let* ([doc (buffers:document b)] [line (if (fx< last (document:line doc (fx- (document:length doc) 1))) (fx+ last 1) last)])
    (%text-start b line)))

(commands:define-command (line [n (commands:prefix-number)])
  "Comments each cursor's lines, or uncomments them when they are commented, then moves past the indentation of the line after them."
  (unless (and (integer? n) (exact? n))
    (assertion-violation 'comment:line "not an exact integer" n))
  (let* ([view (views:command-view 'comment:line)] [b (views:buffer view)])
    (%start 'comment:line b)
    (editing:for-each-cursor view
      (lambda (c p m)
        (let* ([doc (buffers:document b)] [line (document:line doc p)]
               [last-line (document:line doc (fx- (document:length doc) 1))]
               [lines (cond
                        [(and m (not (fx= m p))) (%lines b p m)]
                        [(>= n 0) (%line-range line (fxmax line (fxmin last-line (+ line n -1))))]
                        [else (%line-range (fxmax 1 (+ line n 1)) line)])]
               [last (car (last-pair lines))])
          (%toggle-lines! 'comment:line b lines)
          (editing:place-cursor! view c (%after-lines b last) #f))))))

(define (%region-command who act)
  (let* ([view (views:command-view who)] [b (views:buffer view)])
    (%start who b)
    (editing:check-regions who view)
    (editing:for-each-cursor view
      (lambda (c p m)
        (let ([lines (%lines b p m)])
          (act who b lines)
          (editing:place-cursor! view c (%line-start b (car lines)) #f))))))

(commands:define-command (region)
  "Comments each cursor's lines."
  (%region-command 'comment:region %comment-lines!))

(commands:define-command (uncomment-region)
  "Uncomments each cursor's lines."
  (%region-command 'comment:uncomment-region %uncomment-lines!))

(define (%comment-range b p)
  (let* ([doc (buffers:document b)] [line (document:line doc p)])
    (let-values ([(s e code?) (%line-comment b line)])
      (if s
          (values (if code? (indentation:blanks-start doc 0 s) (%line-start b line)) e)
          (values p p)))))

(commands:define-command (kill [n (commands:prefix-number)])
  "Kills the comment after the code on each of the N lines from each cursor's, with the blanks before it, and a comment alone on its line, which is then indented."
  (unless (and (integer? n) (exact? n))
    (assertion-violation 'comment:kill "not an exact integer" n))
  (let* ([view (views:command-view 'comment:kill)] [b (views:buffer view)])
    (%start 'comment:kill b)
    (let loop ([k n])
      (when (> k 0)
        (let ([alone (filter values
                       (map (lambda (c)
                              (let ([p (views:cursor-point c)])
                                (let-values ([(s e code?) (%line-comment b (document:line (buffers:document b) p))])
                                  (and s (not code?) (buffers:anchor b p)))))
                            (views:cursors view)))])
          (editing:kill-ranges! view %comment-range)
          (for-each (lambda (a) (indentation:line! b (buffers:anchor-position a))) alone))
        (editing:for-each-cursor view
          (lambda (c p m)
            (let ([doc (buffers:document b)])
              (when (> n 1)
                (let ([line (document:line doc p)])
                  (when (fx< line (document:line doc (fx- (document:length doc) 1)))
                    (editing:place-cursor! view c (%line-start b (fx+ line 1)) #f)))))))
        (loop (- k 1))))))

(commands:define-command (set-column)
  "Sets comment-syntax:column in the current buffer to the primary cursor's column."
  (let ([view (views:command-view 'comment:set-column)])
    (options:set-local! comment-syntax:column (indentation:column (views:buffer view) (views:point view)))))

(commands:define-command (indent-new-line)
  "Breaks the line at each cursor; inside a comment that the end of its line ends, starts the new line with the comment's start, at its column, so the comment goes on; elsewhere indents the new line."
  (let*-values ([(view) (views:command-view 'comment:indent-new-line)] [(b) (views:buffer view)]
                [(comment-start comment-end) (comment-syntax:delimiters b)])
    (editing:for-each-cursor view
      (lambda (c p m)
        (let* ([doc (buffers:document b)]
               [in (and comment-start (%lexer? b) (string=? comment-end "")
                        (let ([l (syntax:lexeme-at b p)])
                          (and l (%class? l (syntax:class comment)) (fx< (syntax:lexeme-start l) p)
                               (%starts-with? doc (syntax:lexeme-start l) comment-start)
                               (syntax:lexeme-open-ended? l) l)))]
               [from (indentation:blanks-start doc 0 p)])
          (if in
              (let* ([s (syntax:lexeme-start in)]
                     [run (buffers:text-between doc s (let loop ([q s]) (if (%starts-with? doc q comment-start) (loop (fx+ q (string-length comment-start))) q)))]
                     [text (string-append "\n" (indentation:blanks b 0 (indentation:column b s)) run (padding))])
                (buffers:replace! b from p text)
                (editing:place-cursor! view c (fx+ from (string-length text)) #f))
              (begin
                (buffers:replace! b from p "\n")
                (indentation:line! b (fx+ from 1))
                (let ([doc (buffers:document b)])
                  (editing:place-cursor! view c (%text-start b (document:line doc (fx+ from 1))) #f)))))))))

(keys:bind! keys:global "M-;" dwim)
(keys:bind! keys:global "C-x C-;" line)
(keys:bind! keys:global "C-x ;" set-column)
(keys:bind! keys:global "M-j" indent-new-line)
(keys:bind! keys:global "C-M-j" indent-new-line)
(for-each (lambda (command) (tables:set! commands:region-commands command #t))
          (list dwim line region uncomment-region))
