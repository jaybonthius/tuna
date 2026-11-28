#!tuna
(import (syntax) (indentation) (editing) (buffers) (document) (views) (modes) (commands) (keys) (tables))

(define (%check-count who n)
  (unless (and (integer? n) (exact? n))
    (assertion-violation who "not an exact integer" n)))

(define (%has-lexer? buffer) (and (syntax:lexer (modes:major-mode buffer)) #t))

(define (%check-lexer who buffer)
  (unless (%has-lexer? buffer)
    (error who "the mode has no lexer")))

(define (%class? lexeme class) (eq? (syntax:lexeme-class lexeme) class))

;; A comment holds no sexps, so a cursor in one moves as from its start.
(define (%code-position buffer p)
  (let ([l (syntax:string-or-comment-at buffer p)])
    (if (and l (%class? l (syntax:class comment))) (syntax:lexeme-start l) p)))

(define (%inside-message buffer p)
  (let ([l (syntax:string-or-comment-at buffer p)])
    (and l (if (%class? l (syntax:class string)) "in a string" "in a comment"))))

(define (%sexp-start buffer end) (syntax:sexp-before buffer end))

(define (%sexp-head buffer start end)
  (find (lambda (l) (not (or (%class? l (syntax:class prefix)) (%class? l (syntax:class comment)))))
        (syntax:lexemes buffer start end)))

(define (%list-sexp? buffer start end)
  (let ([head (%sexp-head buffer start end)])
    (and head (%class? head (syntax:class open)) head)))

(define (%sexps-from buffer p n)
  (let loop ([p (%code-position buffer p)] [n n])
    (cond
      [(= n 0) (values p 0)]
      [(> n 0) (let ([e (syntax:sexp-after buffer p)]) (if e (loop e (- n 1)) (values p n)))]
      [else (let ([s (syntax:sexp-before buffer p)]) (if s (loop s (+ n 1)) (values p n)))])))

(define (%sexp-target buffer p n)
  (let-values ([(q left) (%sexps-from buffer p n)])
    (if (= left n) p q)))

(define (%sexp-end buffer p n)
  (let-values ([(q left) (%sexps-from buffer p n)])
    (and (= left 0) q)))

(define (%next-sexp-message n) (if (> n 0) "no next sexp" "no previous sexp"))

(define (%move who n target message)
  (%check-count who n)
  (let* ([view (views:command-view who)] [b (views:buffer view)])
    (%check-lexer who b)
    (editing:move-cursors! who view n
      (lambda (c doc lo hi) (values (target b (views:cursor-point c)) #f))
      message)))

(commands:define-command (forward [n (commands:prefix-number)])
  "Moves each cursor to the end of the Nth sexp after it."
  (%move 'sexp:forward n (lambda (b p) (%sexp-target b p n)) %next-sexp-message))

(commands:define-command (backward [n (commands:prefix-number)])
  "Moves each cursor to the start of the Nth sexp before it."
  (%move 'sexp:backward (- n) (lambda (b p) (%sexp-target b p (- n))) %next-sexp-message))

(define (%lists-from buffer p n)
  (let loop ([p (%code-position buffer p)] [n n] [moved #f])
    (cond
      [(= n 0) moved]
      [(> n 0)
       (let ([e (syntax:sexp-after buffer p)])
         (cond
           [(not e) moved]
           [(%list-sexp? buffer (%sexp-start buffer e) e) (loop e (- n 1) e)]
           [else (loop e n moved)]))]
      [else
       (let ([s (syntax:sexp-before buffer p)])
         (cond
           [(not s) moved]
           [(%list-sexp? buffer s (syntax:sexp-after buffer s))
            => (lambda (open) (loop s (+ n 1) (syntax:lexeme-start open)))]
           [else (loop s n moved)]))])))

(define (%next-list-message n) (if (> n 0) "no next list" "no previous list"))

(commands:define-command (forward-list [n (commands:prefix-number)])
  "Moves each cursor to the end of the Nth list after it, among the sexps of the list holding it."
  (%move 'sexp:forward-list n (lambda (b p) (or (%lists-from b p n) p)) %next-list-message))

(commands:define-command (backward-list [n (commands:prefix-number)])
  "Moves each cursor to the opening bracket of the Nth list before it."
  (%move 'sexp:backward-list (- n) (lambda (b p) (or (%lists-from b p (- n)) p)) %next-list-message))

(define (%list-end buffer open) (syntax:sexp-after buffer (syntax:lexeme-start open)))

(define (%up-from buffer p n backward?)
  (let* ([in (syntax:string-or-comment-at buffer p)]
         [string? (and in (%class? in (syntax:class string)))])
    (let loop ([p (cond [(not string?) (%code-position buffer p)] [backward? (syntax:lexeme-start in)] [else (syntax:lexeme-end in)])]
               [n (if string? (- n 1) n)])
      (let ([openings (syntax:openings buffer p)])
        (if (or (= n 0) (null? openings))
            p
            (let ([open (car (last-pair openings))])
              (loop (if backward? (syntax:lexeme-start open) (or (%list-end buffer open) p)) (- n 1))))))))

(commands:define-command (up-list [n (commands:prefix-number)])
  "Moves each cursor out of N lists, to the end of the Nth list holding it."
  (%move 'sexp:up-list n (lambda (b p) (%up-from b p n #f)) "at top level"))

(commands:define-command (backward-up-list [n (commands:prefix-number)])
  "Moves each cursor back out of N lists, to the opening bracket of the Nth list holding it."
  (%move 'sexp:backward-up-list n (lambda (b p) (%up-from b p n #t)) "at top level"))

(define (%down-from buffer p n)
  (let loop ([p p] [n n])
    (cond
      [(= n 0) p]
      [(> n 0)
       (let next ([q p])
         (let ([e (syntax:sexp-after buffer q)])
           (cond
             [(not e) p]
             [(%list-sexp? buffer (%sexp-start buffer e) e) => (lambda (open) (loop (syntax:lexeme-end open) (- n 1)))]
             [else (next e)])))]
      [else
       (let previous ([q p])
         (let ([s (syntax:sexp-before buffer q)])
           (cond
             [(not s) p]
             [(let ([e (syntax:sexp-after buffer s)])
                (and (%list-sexp? buffer s e)
                     (let ([last (syntax:lexeme-ending-at buffer e)]) (and last (%class? last (syntax:class close)) last))))
              => (lambda (close) (loop (syntax:lexeme-start close) (+ n 1)))]
             [else (previous s)])))])))

(commands:define-command (down-list [n (commands:prefix-number)])
  "Moves each cursor into the next list after it, past its opening bracket, then on down N levels in all; with a negative N, into the previous list, before its closing bracket."
  (let ([view (views:command-view 'sexp:down-list)])
    (%check-lexer 'sexp:down-list (views:buffer view))
    (when (%inside-message (views:buffer view) (views:point view))
      (error 'sexp:down-list "not in a string or comment"))
    (%move 'sexp:down-list n (lambda (b p) (if (%inside-message b p) p (%down-from b p n))) "at bottom level")))

(define (%forms buffer)
  (syntax:top-level-forms buffer 0 (document:length (buffers:document buffer))))

(define (%nth-or-last items n)
  (if (null? items) #f (list-ref items (fxmin (fx- n 1) (fx- (length items) 1)))))

(define (%defun-start buffer p n)
  (let ([forms (%forms buffer)])
    (cond
      [(= n 0) p]
      [(> n 0)
       (let ([f (%nth-or-last (reverse (filter (lambda (f) (fx< (car f) p)) forms)) n)]) (if f (car f) p))]
      [else
       (let ([f (%nth-or-last (filter (lambda (f) (fx> (car f) p)) forms) (- n))]) (if f (car f) p))])))

(define (%past-line-end buffer end)
  (let* ([doc (buffers:document buffer)] [n (fx- (document:length doc) 1)])
    (let loop ([q end])
      (let ([t (and (fx< q n) (document:token doc q))])
        (cond
          [(eqv? t #\newline) (fx+ q 1)]
          [(memv t '(#\space #\tab)) (loop (fx+ q 1))]
          [(and t (let ([l (syntax:lexeme-starting-at buffer q)]) (and l (%class? l (syntax:class comment)) l)))
           => (lambda (l) (loop (syntax:lexeme-end l)))]
          [(not t) q]
          [else end])))))

(define (%defun-end buffer p n)
  (let ([forms (%forms buffer)])
    (cond
      [(= n 0) p]
      [(> n 0)
       (let ([f (%nth-or-last (filter (lambda (f) (fx> (cdr f) p)) forms) n)]) (if f (%past-line-end buffer (cdr f)) p))]
      [else
       (let ([f (%nth-or-last (reverse (filter (lambda (f) (fx< (%past-line-end buffer (cdr f)) p)) forms)) (- n))])
         (if f (%past-line-end buffer (cdr f)) p))])))

(define (%defun-message n) (if (> n 0) "no previous top-level form" "no next top-level form"))

(commands:define-command (beginning-of-defun [n (commands:prefix-number)])
  "Moves each cursor to the start of the Nth top-level form that starts before it; with a negative N, to the start of the -Nth that starts after it."
  (%move 'sexp:beginning-of-defun n (lambda (b p) (%defun-start b p n)) %defun-message))

(commands:define-command (end-of-defun [n (commands:prefix-number)])
  "Moves each cursor to the end of the Nth top-level form that ends after it, and to the next line's start when only blanks and a comment follow it there."
  (%move 'sexp:end-of-defun n (lambda (b p) (%defun-end b p n)) (lambda (n) (%defun-message (- n)))))

;; The primary cursor is planned first, so a command it cannot do raises
;; before anything changes.
(define (%check-primary who view plan)
  (let* ([c (car (views:cursors view))]
         [result (plan (views:buffer view) (views:cursor-point c) (views:cursor-mark c))])
    (when (string? result)
      (error who result))))

(define (%for-each-planned view plan act)
  (let ([b (views:buffer view)])
    (editing:for-each-cursor view
      (lambda (c p m)
        (let ([result (plan b p m)])
          (unless (string? result)
            (act c result)))))))

(define (%sexp-end-plan buffer p n)
  (or (%inside-message buffer p) (%sexp-end buffer p n) (%next-sexp-message n)))

(commands:define-command (mark [n (commands:prefix-number)])
  "Sets each cursor's mark at the end of the Nth sexp after point, or N sexps past its mark."
  (%check-count 'sexp:mark n)
  (let* ([view (views:command-view 'sexp:mark)] [b (views:buffer view)])
    (define (plan buffer point mark)
      (or (%inside-message buffer point) (%sexp-end buffer (or mark point) n) (%next-sexp-message n)))
    (%check-lexer 'sexp:mark b)
    (%check-primary 'sexp:mark view plan)
    (editing:set-marks! view
      (lambda (buffer point mark)
        (let ([result (plan buffer point mark)]) (if (string? result) mark result))))))

(define (%comments-above buffer start)
  (let ([doc (buffers:document buffer)])
    (let loop ([start start])
      (let ([line (document:line doc start)])
        (if (fx<= line 1)
            start
            (let* ([above (document:line-start doc (fx- line 1))]
                   [text (let skip ([q above]) (if (memv (document:token doc q) '(#\space #\tab)) (skip (fx+ q 1)) q))]
                   [l (syntax:lexeme-starting-at buffer text)])
              (if (and l (%class? l (syntax:class comment)) (fx= (syntax:lexeme-end l) (fx- (document:line-start doc line) 1)))
                  (loop above)
                  start)))))))

(commands:define-command (mark-defun [n (commands:prefix-number)])
  "Puts each cursor's point at the start of the top-level form around or after it, with the comment lines above it, and its mark past N forms; a cursor with a mark moves its mark past the next N forms."
  (%check-count 'sexp:mark-defun n)
  (let* ([view (views:command-view 'sexp:mark-defun)] [b (views:buffer view)])
    (define (ends c)
      (let* ([p (views:cursor-point c)] [m (views:cursor-mark c)]
             [forms (%forms b)]
             [first (if m
                        (find (lambda (f) (fx> (cdr f) m)) forms)
                        (or (find (lambda (f) (fx<= (car f) p (cdr f))) forms) (find (lambda (f) (fx> (car f) p)) forms)))])
        (and first
             (let ([after (memq first forms)])
               (and (fx<= n (length after))
                    (cons (if m p (%comments-above b (car first)))
                          (%past-line-end b (cdr (list-ref after (fx- n 1))))))))))
    (%check-lexer 'sexp:mark-defun b)
    (unless (ends (car (views:cursors view)))
      (error 'sexp:mark-defun "no next top-level form"))
    (for-each
      (lambda (c)
        (let ([e (ends c)])
          (when e (editing:place-cursor! view c (car e) (cdr e)))))
      (views:cursors view))))

(define (%kill who n)
  (%check-count who n)
  (let* ([view (views:command-view who)] [b (views:buffer view)])
    (define (plan buffer p m) (%sexp-end-plan buffer p n))
    (%check-lexer who b)
    (%check-primary who view plan)
    (editing:kill-ranges! view
      (lambda (buffer p)
        (let ([result (plan buffer p #f)]) (values p (if (string? result) p result)))))))

(commands:define-command (kill [n (commands:prefix-number)])
  "Kills from each cursor to the end of the Nth sexp after it."
  (%kill 'sexp:kill n))

(commands:define-command (backward-kill [n (commands:prefix-number)])
  "Kills from each cursor back to the start of the Nth sexp before it."
  (%check-count 'sexp:backward-kill n)
  (%kill 'sexp:backward-kill (- n)))

(define (%transpose-plan buffer p m)
  (or (%inside-message buffer p)
      (let* ([s1 (syntax:sexp-before buffer p)]
             [e1 (and s1 (syntax:sexp-after buffer s1))]
             [e2 (and e1 (syntax:sexp-after buffer (if (fx< p e1) e1 p)))]
             [s2 (and e2 (syntax:sexp-before buffer e2))])
        (and s2 (fx<= e1 s2) (list s1 e1 s2 e2)))
      "no two sexps to swap"))

(commands:define-command (transpose)
  "Swaps the sexp before or around each cursor with the sexp after it, and moves the cursor past both."
  (let* ([view (views:command-view 'sexp:transpose)] [b (views:buffer view)])
    (%check-lexer 'sexp:transpose b)
    (%check-primary 'sexp:transpose view %transpose-plan)
    (%for-each-planned view %transpose-plan
      (lambda (c found)
        (apply (lambda (s1 e1 s2 e2)
                 (let ([first (buffers:piece b s1 e1)] [second (buffers:piece b s2 e2)])
                   (buffers:replace! b s2 e2 first)
                   (buffers:replace! b s1 e1 second)
                   (editing:place-cursor! view c e2 #f)))
               found)))))

(define (%raise-plan n)
  (lambda (buffer p m)
    (or (%inside-message buffer p)
        (let ([openings (syntax:openings buffer p)])
          (if (null? openings)
              "at top level"
              (let* ([open (car (last-pair openings))]
                     [start (syntax:lexeme-start open)]
                     [end (%list-end buffer open)])
                (if (and m (not (fx= m p)))
                    (list start end (fxmin p m) (fxmax p m))
                    (let ([e (%sexp-end buffer p n)])
                      (if e (list start end (fxmin p e) (fxmax p e)) (%next-sexp-message n))))))))))

(commands:define-command (raise [n (commands:prefix-number)])
  "Replaces the list holding each cursor with the N sexps after the cursor, or with the cursor's region, and puts the cursor before them."
  (%check-count 'sexp:raise n)
  (let* ([view (views:command-view 'sexp:raise)] [b (views:buffer view)] [plan (%raise-plan n)])
    (%check-lexer 'sexp:raise b)
    (%check-primary 'sexp:raise view plan)
    (%for-each-planned view plan
      (lambda (c found)
        (apply (lambda (start end from to)
                 (buffers:replace! b start end (buffers:piece b from to))
                 (editing:place-cursor! view c start #f))
               found)))))

;; An opening bracket typed after # or #vu8 joins them into one lexeme,
;; such as a vector's #(, which a space between would split.
(define (%joins-before? buffer p open)
  (let ([l (syntax:inserted-lexeme buffer p open)])
    (and l (%class? l (syntax:class open)) (fx< (syntax:lexeme-start l) p))))

(define (%space-before? buffer p open)
  (let ([l (syntax:lexeme-ending-at buffer p)])
    (and l (or (%class? l (syntax:class atom)) (%class? l (syntax:class close)))
         (not (%joins-before? buffer p open)))))

(define (%space-after? buffer p)
  (let ([l (syntax:lexeme-starting-at buffer p)])
    (and l (or (%class? l (syntax:class atom)) (%class? l (syntax:class open))))))

(define (%pair-plan n)
  (lambda (buffer p m)
    (cond
      [(and m (not (fx= m p))) (list (fxmin p m) (fxmax p m) #f)]
      [(not (%has-lexer? buffer)) (if (= n 0) (list p p #f) "the mode has no lexer")]
      [(= n 0) (list p p #t)]
      [(%inside-message buffer p)]
      [(> n 0)
       (let* ([start (indentation:blanks-end (buffers:document buffer) p (fx- (document:length (buffers:document buffer)) 1))] [end (%sexp-end buffer start n)])
         (if end (list start end #t) (%next-sexp-message n)))]
      [else
       (let ([start (%sexp-end buffer p n)])
         (if start (list start p #t) (%next-sexp-message n)))])))

(define (insert-pair view n open close)
  (unless (views:view? view)
    (assertion-violation 'sexp:insert-pair "not a view" view))
  (%check-count 'sexp:insert-pair n)
  (unless (and (string? open) (string? close))
    (assertion-violation 'sexp:insert-pair "not two strings" open close))
  (let ([b (views:buffer view)] [plan (%pair-plan n)])
    (unless b
      (assertion-violation 'sexp:insert-pair "the view shows no buffer" view))
    (%check-primary 'sexp:insert-pair view plan)
    (%for-each-planned view plan
      (lambda (c found)
        (apply (lambda (start end spaces?)
                 (let ([after? (and spaces? (%space-after? b end))]
                       [before? (and spaces? (%space-before? b start open))])
                   (buffers:replace! b end end (if after? (string-append close " ") close))
                   (buffers:replace! b start start (if before? (string-append " " open) open))
                   (editing:place-cursor! view c (fx+ start (string-length open) (if before? 1 0)) #f)))
               found)))))

(commands:define-command (insert-parentheses [n (if (commands:prefix-argument) (commands:prefix-number) 0)])
  "Inserts ( and ) around the N sexps after each cursor, or together at it for 0, or around the cursor's region."
  (insert-pair (views:command-view 'sexp:insert-parentheses) n "(" ")"))

(define (%delete-pair-plan buffer p m)
  (or (%inside-message buffer p)
      (let* ([q (indentation:blanks-end (buffers:document buffer) p (fx- (document:length (buffers:document buffer)) 1))] [l (syntax:lexeme-starting-at buffer q)])
        (cond
          [(and l (%class? l (syntax:class open)))
           (let ([close (syntax:match buffer l)])
             (if (or (not close) (syntax:lexeme-mismatched? close))
                 "the brackets do not match"
                 (list (syntax:lexeme-start l) (syntax:lexeme-end l) (syntax:lexeme-start close) (syntax:lexeme-end close))))]
          [(and l (%class? l (syntax:class string)) (not (syntax:lexeme-open-ended? l)))
           (list (syntax:lexeme-start l) (fx+ (syntax:lexeme-start l) 1) (fx- (syntax:lexeme-end l) 1) (syntax:lexeme-end l))]
          [else "not before a list or string"]))))

(commands:define-command (delete-pair)
  "Deletes the brackets of the list after each cursor, or the quotes of the string there."
  (let* ([view (views:command-view 'sexp:delete-pair)] [b (views:buffer view)])
    (%check-lexer 'sexp:delete-pair b)
    (%check-primary 'sexp:delete-pair view %delete-pair-plan)
    (%for-each-planned view %delete-pair-plan
      (lambda (c found)
        (apply (lambda (open-start open-end close-start close-end)
                 (buffers:replace! b close-start close-end "")
                 (buffers:replace! b open-start open-end ""))
               found)))))

(define (%first-unmatched buffer)
  (let loop ([ls (syntax:lexemes buffer 0 (document:length (buffers:document buffer)))] [open '()])
    (if (null? ls)
        (and (pair? open) (syntax:lexeme-start (car (last-pair open))))
        (let ([l (car ls)])
          (cond
            [(%class? l (syntax:class open)) (loop (cdr ls) (cons l open))]
            [(%class? l (syntax:class close))
             (if (or (fx= (syntax:lexeme-depth l) 0) (null? open) (syntax:lexeme-mismatched? l))
                 (syntax:lexeme-start l)
                 (loop (cdr ls) (cdr open)))]
            [(and (%class? l (syntax:class string)) (syntax:lexeme-open-ended? l))
             (if (pair? open) (fxmin (syntax:lexeme-start l) (syntax:lexeme-start (car (last-pair open)))) (syntax:lexeme-start l))]
            [else (loop (cdr ls) open)])))))

(commands:define-command (check-parens)
  "Moves the primary cursor to the first bracket or quote without its match and raises; does nothing when there is none."
  (let* ([view (views:command-view 'sexp:check-parens)] [b (views:buffer view)])
    (%check-lexer 'sexp:check-parens b)
    (let ([at (%first-unmatched b)])
      (when at
        (for-each (lambda (c) (views:remove-cursor! view c)) (cdr (views:cursors view)))
        (editing:place-cursor! view (car (views:cursors view)) at #f)
        (error 'sexp:check-parens "unmatched bracket or quote")))))

(define (%text-of buffer lexeme)
  (buffers:text-between (buffers:document buffer) (syntax:lexeme-start lexeme) (syntax:lexeme-end lexeme)))

(define (%blanks-back buffer q low)
  (let ([doc (buffers:document buffer)])
    (let loop ([q q]) (if (and (fx> q low) (memv (document:token doc (fx- q 1)) '(#\space #\tab #\newline))) (loop (fx- q 1)) q))))

(define (%holding-list buffer p)
  (let ([openings (syntax:openings buffer p)])
    (and (pair? openings)
         (let* ([open (car (last-pair openings))] [close (syntax:match buffer open)])
           (and close (cons open close))))))

(define (%structure-plan make)
  (lambda (buffer p m)
    (or (%inside-message buffer p)
        (let ([brackets (%holding-list buffer p)])
          (if brackets (make buffer p (car brackets) (cdr brackets)) "at top level")))))

(define (%apply-structure! view c plan)
  (let* ([b (views:buffer view)]
         [edits (list-sort (lambda (x y) (fx> (car x) (car y))) (car plan))]
         [place (buffers:anchor b (cadr plan))]
         [from (buffers:anchor b (cadddr plan))]
         [to (buffers:anchor-after b (car (cddddr plan)))])
    (for-each (lambda (e) (buffers:replace! b (car e) (cadr e) (caddr e))) edits)
    (indentation:lines! b (buffers:anchor-position from) (buffers:anchor-position to))
    (editing:place-cursor! view c (fx+ (buffers:anchor-position place) (caddr plan)) #f)))

(define (%structure-command who plan)
  (let* ([view (views:command-view who)] [b (views:buffer view)])
    (%check-lexer who b)
    (%check-primary who view plan)
    (%for-each-planned view plan (lambda (c found) (%apply-structure! view c found)))))

(define (%outer-start buffer open)
  (let ([outer (syntax:openings buffer (syntax:lexeme-start open))])
    (if (null? outer) (syntax:lexeme-start open) (syntax:lexeme-start (car (last-pair outer))))))

(define (%slurp-forward-plan n)
  (%structure-plan
    (lambda (buffer p open close)
      (let ([e (%sexp-end buffer (syntax:lexeme-end close) n)])
        (if e
            (list (list (list (syntax:lexeme-start close) (syntax:lexeme-end close) "") (list e e (%text-of buffer close)))
                  p 0 (syntax:lexeme-start open) e)
            "no next sexp")))))

(define (%barf-forward-plan n)
  (%structure-plan
    (lambda (buffer p open close)
      (let ([s (%sexp-end buffer (syntax:lexeme-start close) (- n))])
        (if (and s (fx>= s (syntax:lexeme-end open)))
            (let ([q (%blanks-back buffer s (syntax:lexeme-end open))])
              (list (list (list (syntax:lexeme-start close) (syntax:lexeme-end close) "") (list q q (%text-of buffer close)))
                    p 0 (syntax:lexeme-start open) (syntax:lexeme-end close)))
            "no sexp to give up")))))

(define (%slurp-backward-plan n)
  (%structure-plan
    (lambda (buffer p open close)
      (let ([s (%sexp-end buffer (syntax:lexeme-start open) (- n))])
        (if s
            (list (list (list (syntax:lexeme-start open) (syntax:lexeme-end open) "") (list s s (%text-of buffer open)))
                  p 0 s (syntax:lexeme-end close))
            "no previous sexp")))))

(define (%barf-backward-plan n)
  (%structure-plan
    (lambda (buffer p open close)
      (let ([e (%sexp-end buffer (syntax:lexeme-end open) n)])
        (if (and e (fx<= e (syntax:lexeme-start close)))
            (let ([q (%after-blanks-and-breaks buffer e (syntax:lexeme-start close))])
              (list (list (list (syntax:lexeme-start open) (syntax:lexeme-end open) "") (list q q (%text-of buffer open)))
                    p (if (fx= q p) (fx- (syntax:lexeme-end open) (syntax:lexeme-start open)) 0)
                    (syntax:lexeme-start open) (syntax:lexeme-end close)))
            "no sexp to give up")))))

(define (%after-blanks-and-breaks buffer q high)
  (let ([doc (buffers:document buffer)])
    (let loop ([q q]) (if (and (fx< q high) (memv (document:token doc q) '(#\space #\tab #\newline))) (loop (fx+ q 1)) q))))

(define (%slurp who plan-of barf-plan-of n)
  (%check-count who n)
  (%structure-command who (if (< n 0) (barf-plan-of (- n)) (plan-of n))))

(commands:define-command (slurp-forward [n (commands:prefix-number)])
  "Moves the closing bracket of the list holding each cursor past the N sexps after it."
  (%slurp 'sexp:slurp-forward %slurp-forward-plan %barf-forward-plan n))

(commands:define-command (barf-forward [n (commands:prefix-number)])
  "Moves the closing bracket of the list holding each cursor back before its last N sexps."
  (%slurp 'sexp:barf-forward %barf-forward-plan %slurp-forward-plan n))

(commands:define-command (slurp-backward [n (commands:prefix-number)])
  "Moves the opening bracket of the list holding each cursor back over the N sexps before it."
  (%slurp 'sexp:slurp-backward %slurp-backward-plan %barf-backward-plan n))

(commands:define-command (barf-backward [n (commands:prefix-number)])
  "Moves the opening bracket of the list holding each cursor forward past its first N sexps."
  (%slurp 'sexp:barf-backward %barf-backward-plan %slurp-backward-plan n))

(define (%string-at buffer p)
  (let ([l (syntax:string-or-comment-at buffer p)])
    (and l (%class? l (syntax:class string)) (not (syntax:lexeme-open-ended? l)) l)))

(define (%splice-plan buffer p m)
  (let ([string (%string-at buffer p)])
    (cond
      [string
       (let ([s (syntax:lexeme-start string)] [e (syntax:lexeme-end string)])
         (list (list (list s (fx+ s 1) "") (list (fx- e 1) e "")) p 0 s e))]
      [(%inside-message buffer p)]
      [(%holding-list buffer p)
       => (lambda (brackets)
            (let ([open (car brackets)] [close (cdr brackets)])
              (list (list (list (syntax:lexeme-start open) (syntax:lexeme-end open) "")
                          (list (syntax:lexeme-start close) (syntax:lexeme-end close) ""))
                    p 0 (%outer-start buffer open) (syntax:lexeme-end close))))]
      [else "at top level"])))

(commands:define-command (splice)
  "Deletes the brackets of the list holding each cursor, keeping what is inside; inside a string, deletes its quotes."
  (%structure-command 'sexp:splice %splice-plan))

(define (%split-plan buffer p m)
  (let ([string (%string-at buffer p)])
    (cond
      [string
       (let ([mark (buffers:text-between (buffers:document buffer) (fx- (syntax:lexeme-end string) 1) (syntax:lexeme-end string))])
         (list (list (list p p (string-append mark " " mark))) p (string-length mark) p p))]
      [(%inside-message buffer p)]
      [(%holding-list buffer p)
       => (lambda (brackets)
            (let* ([open (car brackets)] [close (cdr brackets)]
                   [open-text (%text-of buffer open)]
                   [start (%after-blanks-and-breaks buffer p (syntax:lexeme-start close))]
                   [at (%blanks-back buffer p (syntax:lexeme-end open))])
              (list (list (list at at (%text-of buffer close))
                          (list start start (substring open-text (fx- (string-length open-text) 1) (string-length open-text))))
                    at (fx- (syntax:lexeme-end close) (syntax:lexeme-start close)) (syntax:lexeme-start open) (syntax:lexeme-end close))))]
      [else "at top level"])))

(commands:define-command (split)
  "Closes the list or string holding each cursor at the cursor and opens one of the same kind after it, so one becomes two."
  (%structure-command 'sexp:split %split-plan))

(define (%join-plan buffer p m)
  (or (%inside-message buffer p)
      (let* ([before (let ([s (syntax:sexp-before buffer p)]) (and s (syntax:sexp-after buffer s)))]
             [after (syntax:sexp-after buffer p)]
             [first-end (and before (syntax:lexeme-ending-at buffer before))]
             [second (and after (syntax:sexp-before buffer after))]
             [second-start (and second (syntax:lexeme-starting-at buffer second))])
        (cond
          [(and first-end second-start (%class? first-end (syntax:class close)) (%class? second-start (syntax:class open)))
           (list (list (list (syntax:lexeme-start first-end) (syntax:lexeme-end first-end) "")
                       (list (syntax:lexeme-start second-start) (syntax:lexeme-end second-start) ""))
                 (syntax:lexeme-start first-end) 0 (syntax:lexeme-start first-end) after)]
          [(and first-end second-start (%class? first-end (syntax:class string)) (%class? second-start (syntax:class string)))
           (list (list (list (fx- before 1) (fx+ second 1) ""))
                 (fx- before 1) 0 (fx- before 1) after)]
          [else "no list or string to join"]))))

(commands:define-command (join)
  "Joins the two lists, or the two strings, on either side of each cursor into one."
  (%structure-command 'sexp:join %join-plan))

(keys:bind! keys:global "C-M-f" forward)
(keys:bind! keys:global "C-M-<right>" forward)
(keys:bind! keys:global "C-M-b" backward)
(keys:bind! keys:global "C-M-<left>" backward)
(keys:bind! keys:global "C-M-n" forward-list)
(keys:bind! keys:global "C-M-p" backward-list)
(keys:bind! keys:global "C-M-u" backward-up-list)
(keys:bind! keys:global "C-M-<up>" backward-up-list)
(keys:bind! keys:global "C-M-d" down-list)
(keys:bind! keys:global "C-M-<down>" down-list)
(keys:bind! keys:global "C-M-a" beginning-of-defun)
(keys:bind! keys:global "C-M-<home>" beginning-of-defun)
(keys:bind! keys:global "C-M-e" end-of-defun)
(keys:bind! keys:global "C-M-<end>" end-of-defun)
(keys:bind! keys:global "C-M-SPC" mark)
(keys:bind! keys:global "C-M-@" mark)
(keys:bind! keys:global "C-M-h" mark-defun)
(keys:bind! keys:global "C-M-k" kill)
(keys:bind! keys:global "C-M-DEL" backward-kill)
(keys:bind! keys:global "C-M-<delete>" backward-kill)
(keys:bind! keys:global "C-M-t" transpose)
(keys:bind! keys:global "M-(" insert-parentheses)
(for-each (lambda (command) (tables:set! commands:region-commands command #t))
          (list raise insert-parentheses))
