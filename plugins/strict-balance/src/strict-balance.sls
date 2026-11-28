#!tuna
(import (syntax) (syntax characters) (sexp) (comment) (indentation) (editing) (buffers) (document) (views) (modes) (commands)
        (keys) (ask) (tables))

(tables:define-table keymap
  "Remaps editing's typing, deleting and killing commands while strict-balance:mode is on.")

(modes:define-minor-mode mode
  "Whether typing, deleting and killing keep every bracket and string quote with its partner."
  (lighter "Strict")
  (keymap keymap))

(define (%lexer? b) (and (syntax:lexer (modes:major-mode b)) #t))

(define (%class? lexeme class) (eq? (syntax:lexeme-class lexeme) class))

(define (%escape? prefix) (pair? prefix))

;; Asking the lexer about the character alone keeps the plugin free of any
;; language's characters, as syntax decides which characters open a list
;; inside a comment.
(define (%delimiter-char? b c)
  (let ([v ((syntax:lexer (modes:major-mode b)) (document:from-datum (string c)))])
    (and (fx= (vector-length v) 1)
         (memq (syntax:lexeme-class (vector-ref v 0)) '(open close string comment))
         #t)))

(define (%char-at b p)
  (let ([doc (buffers:document b)])
    (and (fx>= p 0) (fx< p (document:length doc))
         (let ([t (document:token doc p)]) (and (char? t) t)))))

;; An atom holding a delimiter, such as the character literal #\(, is
;; deleted whole, since a part of it would read as a bracket or quote.
(define (%delimiter-atom b position)
  (let ([ls (syntax:lexemes b position (fx+ position 1))])
    (and (pair? ls)
         (let ([l (car ls)])
           (and (%class? l (syntax:class atom)) (fx<= (syntax:lexeme-start l) position) (fx< position (syntax:lexeme-end l))
                (let loop ([q (syntax:lexeme-start l)])
                  (and (fx< q (syntax:lexeme-end l))
                       (or (let ([c (%char-at b q)]) (and c (%delimiter-char? b c)))
                           (loop (fx+ q 1)))))
                l)))))

(define (%refusing who view act)
  (let ([refused '()] [cursors 0])
    (editing:for-each-cursor view
      (lambda (c p m)
        (set! cursors (fx+ cursors 1))
        (let ([refusal (act c p m)])
          (when refusal (set! refused (cons refusal refused))))))
    (when (and (pair? refused) (fx= (length refused) cursors))
      (error who (car (last-pair refused))))))

(define (%region-balanced? view c)
  (let ([b (views:buffer view)])
    (for-all (lambda (r) (syntax:balanced? b (car r) (cdr r) "")) (views:region-bounds view c))))

;; Every command that replaces the selection asks this, so typing, C-q,
;; RET, a paste and C-y over an unbalanced region are refused as DEL is;
;; C-u forces them.
(define (%balanced-selection replace-selection? view cursor)
  (when (and (%mode-on? view)
             (not (%escape? (commands:prefix-argument)))
             (not (%region-balanced? view cursor)))
    (error (let ([command (commands:this-command)]) (if command (commands:command-name command) 'strict-balance:mode))
           "the region is not balanced"))
  (replace-selection? view cursor))

(define (%check-regions-balanced who view cursors)
  (unless (for-all (lambda (c) (%region-balanced? view c)) cursors)
    (error who "the region is not balanced")))

(define (%wraps-region? view)
  (exists (lambda (c) (pair? (views:region-bounds view c))) (views:cursors view)))

(define (%insert-pair! who view prefix open close)
  (when (%wraps-region? view)
    (%check-regions-balanced who view (views:cursors view)))
  (sexp:insert-pair view (if prefix (commands:prefix-number) 0) (string open) (string close)))

(define (%close! view char)
  (let ([b (views:buffer view)])
    (%refusing 'strict-balance:self-insert view
      (lambda (c p m)
        (let ([openings (syntax:openings b p)])
          (if (null? openings)
              "not inside a list"
              (let* ([open (car (last-pair openings))] [close (syntax:match b open)])
                (if close
                    (let* ([s (syntax:lexeme-start close)]
                           [blanks (let loop ([q s]) (if (memv (%char-at b (fx- q 1)) '(#\space #\tab #\newline)) (loop (fx- q 1)) q))])
                      (if (syntax:balanced? b blanks s "")
                          (begin
                            (buffers:replace! b blanks s "")
                            (editing:place-cursor! view c (fx+ blanks (fx- (syntax:lexeme-end close) s)) #f))
                          (begin
                            (indentation:line! b s)
                            (editing:place-cursor! view c (syntax:lexeme-end (syntax:match b open)) #f)))
                      #f)
                    (let* ([text (buffers:text-between (buffers:document b) (syntax:lexeme-start open) (syntax:lexeme-end open))]
                           [pair (find (lambda (pr) (char=? (car pr) (string-ref text (fx- (string-length text) 1))))
                                       (syntax:mode-bracket-pairs (modes:major-mode b)))]
                           [closer (string (if pair (cdr pair) char))]
                           ;; The closer goes back over blanks only where it
                           ;; would read as a closer, not into a comment or a
                           ;; character literal such as #\ .
                           [blanks (let loop ([q p])
                                     (if (and (fx> q (syntax:lexeme-end open)) (memv (%char-at b (fx- q 1)) '(#\space #\tab #\newline))
                                              (let ([l (syntax:inserted-lexeme b (fx- q 1) closer)])
                                                (and l (%class? l (syntax:class close)))))
                                         (loop (fx- q 1))
                                         q))])
                      (buffers:replace! b blanks p closer)
                      (editing:place-cursor! view c (fx+ blanks 1) #f)
                      (ask:message "inserted a missing bracket")
                      #f)))))))))

;; An unescaped quote would end the string where it is typed, and one typed
;; between an escape and its character would turn the escape into an
;; escaped escape, so it goes after the character.
(define (%quote-in-string! view char)
  (let ([b (views:buffer view)])
    (editing:for-each-cursor view
      (lambda (c p m)
        (let ([l (syntax:string-or-comment-at b p)])
          (cond
            [(and l (%class? l (syntax:class string)) (not (syntax:lexeme-open-ended? l))
                  (fx= p (fx- (syntax:lexeme-end l) 1)) (eqv? (%char-at b p) char))
             (editing:place-cursor! view c (syntax:lexeme-end l) #f)]
            [(and l (%class? l (syntax:class string)))
             (let ([escape (syntax:mode-escape (modes:major-mode b))]
                   [at (if (%escape-at? b l (fx- p 1)) (fx+ p 1) p)])
               (unless escape
                 (error 'strict-balance:self-insert "the mode's strings have no escape"))
               (buffers:replace! b at at (string escape char))
               (editing:place-cursor! view c (fx+ at 2) #f))]
            [else
             (buffers:replace! b p p (string char))
             (editing:place-cursor! view c (fx+ p 1) #f)]))))))

;; A line comment started before a lexeme that ends on a later line, a
;; list, string or comment, or before the end of the list holding it,
;; would take a bracket from its partner, so the line breaks before them,
;; as paredit's ; does; read from the line's own lexemes, so a comment
;; that spans lines counts.
(define (%comment-break b p)
  (let ([line-end (%line-end b p)])
    (let loop ([ls (syntax:lexemes b p line-end)])
      (and (pair? ls)
           (let* ([l (car ls)] [start (syntax:lexeme-start l)])
             (cond
               [(fx< start p) (loop (cdr ls))]
               [(%class? l (syntax:class close))
                (let ([open (syntax:match b l)]) (if (and open (fx< (syntax:lexeme-start open) p)) start (loop (cdr ls))))]
               [(fx> (%reach b l) line-end) start]
               [else (loop (cdr ls))]))))))

(define (%reach b l)
  (if (%class? l (syntax:class open))
      (let ([close (syntax:match b l)])
        (if close (syntax:lexeme-end close) (document:length (buffers:document b))))
      (syntax:lexeme-end l)))

(define (%comment-start! view char)
  (let* ([b (views:buffer view)] [doc (buffers:document b)])
    (for-each
      (lambda (c)
        (let* ([p (views:cursor-point c)] [break (%comment-break b p)])
          (unless (if break
                      (syntax:balanced? b p break
                        (string-append (string char) (buffers:text-between doc p (indentation:blanks-start doc p break)) "\n"))
                      (syntax:balanced? b p p (string char)))
            (error 'strict-balance:self-insert %crossing))))
      (views:cursors view))
    (editing:for-each-cursor view
      (lambda (c p m)
        (let* ([doc (buffers:document b)]
               [break (%comment-break b p)]
               [at (and break (indentation:blanks-start doc p break))]
               [break-anchor (and break (buffers:anchor-after b break))])
          (buffers:replace! b p p (string char))
          (editing:place-cursor! view c (fx+ p 1) #f)
          (when break
            (buffers:replace! b (fx+ at 1) (buffers:anchor-position break-anchor) "\n")
            (indentation:line! b (fx+ at 2))))))))

(define (%reads b p char)
  (let ([l (syntax:inserted-lexeme b p (string char))])
    (values l (and l (fx< (syntax:lexeme-start l) p)))))

(commands:define-command (self-insert [prefix (commands:prefix-argument)] [char (keys:typed-char)])
  "Inserts CHAR, by default the character typed, keeping brackets and quotes with their partners: an opening bracket with its closing one, a closing bracket by moving past the list's end, a quote as a pair, a comment start before a closing bracket by moving the bracket to the next line."
  (let* ([view (views:command-view 'strict-balance:self-insert)] [b (views:buffer view)] [primary (views:point view)])
    (unless (char? char)
      (assertion-violation 'strict-balance:self-insert "not a character" char))
    (cond
      [(or (%escape? prefix) (not (%lexer? b)) (word-char? char (syntax:buffer-word-characters b)))
       (editing:self-insert (commands:prefix-number) char)]
      [(and (eqv? char (syntax:mode-escape (modes:major-mode b)))
            (not (let ([in (syntax:string-or-comment-at b primary)]) (and in (%class? in (syntax:class comment))))))
       (%escape! view char)]
      [(not (%delimiter-char? b char)) (%typed! view char)]
      [else
        (let ([pairs (syntax:mode-bracket-pairs (modes:major-mode b))]
              [inside (syntax:string-or-comment-at b primary)])
          (if inside
              (if (and (%class? inside (syntax:class string)) (%quote-char? b char))
                  (%quote-in-string! view char)
                  (%typed! view char))
              (let-values ([(l joined?) (%reads b primary char)])
                (cond
                  ;; After #\ the character only ends a character literal, a
                  ;; split no command makes; C-q inserts it.
                  [(and joined? (%class? l (syntax:class atom)))]
                  [(and (%class? l (syntax:class open)) (assv char pairs))
                   => (lambda (pr) (%insert-pair! 'strict-balance:self-insert view prefix char (cdr pr)))]
                  [(exists (lambda (pr) (char=? (cdr pr) char)) pairs) (%close! view char)]
                  [(and (%class? l (syntax:class string)) (not joined?))
                   (%insert-pair! 'strict-balance:self-insert view prefix char char)]
                  [(and (%class? l (syntax:class comment)) (not joined?)) (%comment-start! view char)]
                  [else (%typed! view char)]))))])))

;; A character that is no bracket or quote of the list around it can still
;; start or end a comment, as | after # does, or be a bracket inside one.
(define (%typed! view char)
  (%refuse-unbalanced-insert! 'strict-balance:self-insert view (make-string (commands:prefix-number) char))
  (editing:self-insert (commands:prefix-number) char))

;; An escape alone escapes whatever follows it, a string's closing quote
;; or a list's closing bracket, so it goes in with the next key's
;; character, as paredit's \ does.
(define (%escape! view escape)
  (let* ([char (keys:key-char (keys:read-key))] [text (and char (string escape char))])
    (when text
      (%refuse-unbalanced-insert! 'strict-balance:self-insert view text)
      (editing:insert! view text))))

(define (%quote-char? b char)
  (let ([v ((syntax:lexer (modes:major-mode b)) (document:from-datum (string char)))])
    (and (fx= (vector-length v) 1) (%class? (vector-ref v 0) (syntax:class string)))))

(define (%escape-at? b lexeme q)
  (let ([escape (syntax:mode-escape (modes:major-mode b))] [s (syntax:lexeme-start lexeme)]
        [first (if (%class? lexeme (syntax:class string)) (fx+ (syntax:lexeme-start lexeme) 1) (syntax:lexeme-start lexeme))])
    (and escape (fx>= q first) (fx< q (syntax:lexeme-end lexeme)) (eqv? (%char-at b q) escape)
         (let loop ([k q] [n 0])
           (if (and (fx>= k first) (eqv? (%char-at b k) escape)) (loop (fx- k 1) (fx+ n 1)) (odd? n))))))

(define (%string-text-end string)
  (if (syntax:lexeme-open-ended? string) (syntax:lexeme-end string) (fx- (syntax:lexeme-end string) 1)))

(define %crossing "the text moving into or out of a comment, string or symbol is not balanced")

(define (%plain b from to)
  (if (syntax:balanced? b from to "") '(plain) %crossing))

(define (%escape-atom b p)
  (let ([l (or (syntax:lexeme-at b p) (syntax:lexeme-ending-at b p))])
    (and l (%class? l (syntax:class atom)) l)))

(define (%backward-plan b p)
  (let ([in (syntax:string-or-comment-at b p)] [before (syntax:lexeme-ending-at b p)])
    (cond
      [(fx<= p 1) "beginning of buffer"]
      [(and in (%class? in (syntax:class string)))
       (let ([s (syntax:lexeme-start in)])
         (cond
           [(fx= (fx- p 1) s)
            (if (and (not (syntax:lexeme-open-ended? in)) (fx= (syntax:lexeme-end in) (fx+ p 1)))
                (list 'delete s (fx+ p 1))
                "beginning of list")]
           [(%escape-at? b in (fx- p 2)) (list 'delete (fx- p 2) p)]
           [(and (%escape-at? b in (fx- p 1)) (fx< p (%string-text-end in))) (list 'delete (fx- p 1) (fx+ p 1))]
           [else '(plain)]))]
      [in (%plain b (fx- p 1) p)]
      [(and before (%class? before (syntax:class close)))
       (if (syntax:match b before)
           (list 'move (syntax:lexeme-start before))
           (list 'spurious (syntax:lexeme-start before) p))]
      [(and before (%class? before (syntax:class string)) (not (syntax:lexeme-open-ended? before)))
       (list 'move (fx- p 1))]
      [(and before (%class? before (syntax:class open)))
       (let ([close (syntax:match b before)])
         (cond
           [(not close) (list 'spurious (syntax:lexeme-start before) p)]
           [(fx= (syntax:lexeme-start close) p) (list 'delete (syntax:lexeme-start before) (syntax:lexeme-end close))]
           [else "beginning of list"]))]
      [(%delimiter-atom b (fx- p 1)) => (lambda (l) (list 'delete (syntax:lexeme-start l) (syntax:lexeme-end l)))]
      [(%escape-atom b p)
       => (lambda (atom)
            (cond
              [(%escape-at? b atom (fx- p 2)) (list 'delete (fx- p 2) p)]
              [(and (%escape-at? b atom (fx- p 1)) (fx< p (syntax:lexeme-end atom))) (list 'delete (fx- p 1) (fx+ p 1))]
              [else (%plain b (fx- p 1) p)]))]
      [else (%plain b (fx- p 1) p)])))

(define (%forward-plan b p)
  (let ([in (syntax:string-or-comment-at b p)] [after (syntax:lexeme-starting-at b p)] [last (fx- (document:length (buffers:document b)) 1)])
    (cond
      [(fx>= p last) "end of buffer"]
      [(and in (%class? in (syntax:class string)))
       (let ([s (syntax:lexeme-start in)] [e (syntax:lexeme-end in)])
         (cond
           [(and (not (syntax:lexeme-open-ended? in)) (fx= p (fx- e 1)))
            (if (fx= p (fx+ s 1)) (list 'delete s e) "end of list")]
           [(%escape-at? b in p) (list 'delete p (fx+ p 2))]
           [(%escape-at? b in (fx- p 1)) (list 'delete (fx- p 1) (fx+ p 1))]
           [else '(plain)]))]
      [in (%plain b p (fx+ p 1))]
      [(and after (%class? after (syntax:class open)))
       (let ([close (syntax:match b after)])
         (cond
           [(not close) (list 'spurious p (syntax:lexeme-end after))]
           [(fx= (syntax:lexeme-start close) (syntax:lexeme-end after)) (list 'delete p (syntax:lexeme-end close))]
           [else (list 'move (syntax:lexeme-end after))]))]
      [(and after (%class? after (syntax:class close)))
       (let ([open (syntax:match b after)])
         (cond
           [(not open) (list 'spurious p (syntax:lexeme-end after))]
           [(fx= (syntax:lexeme-end open) p) (list 'delete (syntax:lexeme-start open) (syntax:lexeme-end after))]
           [else "end of list"]))]
      [(and after (%class? after (syntax:class string)))
       (if (fx= (syntax:lexeme-end after) (fx+ p 2)) (list 'delete p (fx+ p 2)) (list 'move (fx+ p 1)))]
      [(%delimiter-atom b p) => (lambda (l) (list 'delete (syntax:lexeme-start l) (syntax:lexeme-end l)))]
      [(let ([l (syntax:lexeme-at b p)]) (and l (%class? l (syntax:class open)) l))
       => (lambda (open) (list 'move (syntax:lexeme-end open)))]
      [(or (syntax:lexeme-at b p) (syntax:lexeme-starting-at b p))
       => (lambda (l)
            (cond
              [(not (%class? l (syntax:class atom))) (%plain b p (fx+ p 1))]
              [(%escape-at? b l p) (list 'delete p (fx+ p 2))]
              [(%escape-at? b l (fx- p 1)) (list 'delete (fx- p 1) (fx+ p 1))]
              [else (%plain b p (fx+ p 1))]))]
      [else (%plain b p (fx+ p 1))])))

(define (%act! view c p plan)
  (let ([b (views:buffer view)])
    (case (car plan)
      [(delete spurious)
       (buffers:replace! b (cadr plan) (caddr plan) "")
       (editing:place-cursor! view c (cadr plan) #f)
       (when (eq? (car plan) 'spurious) (ask:message "deleted a bracket with no match"))]
      [(move) (editing:place-cursor! view c (cadr plan) #f)]
      [else
       (let ([q (if (eq? (car plan) 'plain-backward) (fx- p 1) (fx+ p 1))])
         (buffers:replace! b (fxmin p q) (fxmax p q) "")
         (editing:place-cursor! view c (fxmin p q) #f))])))

(define (%plain? plan) (and (pair? plan) (eq? (car plan) 'plain)))

;; Editing's own command deletes when every cursor's character is plain,
;; so its rules for grapheme clusters and regions hold.
(define (%delete-step! who view plan-of plain! backward?)
  (let ([b (views:buffer view)])
    (if (for-all (lambda (c) (%plain? (plan-of b (views:cursor-point c) (views:cursor-mark c)))) (views:cursors view))
        (plain!)
        (%refusing who view
          (lambda (c p m)
            (let ([plan (plan-of b p m)])
              (cond
                [(string? plan) plan]
                [(%plain? plan) (%act! view c p (list (if backward? 'plain-backward 'plain-forward))) #f]
                [else (%act! view c p plan) #f])))))))

;; Where some cursors have a region the command deletes and others do
;; not, each takes its own rule, so a cursor with no region is not left to
;; editing's plain deletion.
(define (%region-or plan-of deletes-region?)
  (lambda (b p m)
    (if (and deletes-region? m (not (fx= m p)))
        (if (syntax:balanced? b (fxmin p m) (fxmax p m) "")
            (list 'delete (fxmin p m) (fxmax p m))
            "the region is not balanced")
        (plan-of b p))))

(define (%delete! who prefix region-option? editing-command backward?)
  (let* ([view (views:command-view who)] [b (views:buffer view)] [n (commands:prefix-number)]
         [regions? (region-option? n)]
         [has-region? (lambda (c) (pair? (views:region-bounds view c)))])
    (cond
      [(%escape? prefix) (editing-command 1)]
      [(or (not (%lexer? b)) (and regions? (for-all has-region? (views:cursors view)))) (editing-command n)]
      [else
       (let ([forward? (not (eq? backward? (> n 0)))])
         (let loop ([k (abs n)])
           (when (> k 0)
             (%delete-step! who view (%region-or (if forward? %forward-plan %backward-plan) regions?)
               (lambda () (editing-command (if (> n 0) 1 -1))) (not forward?))
             (loop (- k 1)))))])))

(commands:define-command (delete-backward-char [prefix (commands:prefix-argument)])
  "Deletes the character before each cursor, moving back over a closing bracket or quote instead, deleting an empty pair whole and refusing an opening one; C-u deletes one character whatever it is."
  (%delete! 'strict-balance:delete-backward-char prefix
    (lambda (n) (or (editing:delete-selection) (and (editing:delete-active-region) (= n 1))))
    editing:delete-backward-char #t))

(commands:define-command (delete-char [prefix (commands:prefix-argument)])
  "Deletes the character after each cursor by the rules of strict-balance:delete-backward-char, mirrored."
  (%delete! 'strict-balance:delete-char prefix (lambda (n) (editing:delete-selection)) editing:delete-char #f))

(commands:define-command (delete-forward-char [prefix (commands:prefix-argument)])
  "Deletes the character after each cursor as strict-balance:delete-char does."
  (%delete! 'strict-balance:delete-forward-char prefix
    (lambda (n) (or (editing:delete-selection) (and (editing:delete-active-region) (= n 1))))
    editing:delete-forward-char #f))

(define (%line-end b p) (let-values ([(start end) (editing:lines-bounds b p #f)]) end))

(define (%after-line-end b p)
  (let ([end (%line-end b p)])
    (if (fx< end (fx- (document:length (buffers:document b)) 1)) (fx+ end 1) end)))

(define (%blank-to? doc from to)
  (let loop ([q from]) (or (fx>= q to) (and (memv (document:token doc q) '(#\space #\tab)) (loop (fx+ q 1))))))

(define (%kill-line-end b p)
  (let* ([doc (buffers:document b)] [line-end (%line-end b p)] [in (syntax:string-or-comment-at b p)])
    (cond
      [(and in (%class? in (syntax:class string))) (fxmin line-end (%string-text-end in))]
      [(%blank-to? doc p line-end) (%after-line-end b p)]
      [in line-end]
      [else
       (let loop ([ls (syntax:lexemes b p line-end)] [q p])
         (cond
           [(null? ls) q]
           [(fx< (syntax:lexeme-start (car ls)) q) (loop (cdr ls) (fxmax q (if (fx< (syntax:lexeme-start (car ls)) p) (%reach b (car ls)) q)))]
           [(%class? (car ls) (syntax:class close)) q]
           [(fx> (%reach b (car ls)) line-end) (%reach b (car ls))]
           [else (loop (cdr ls) (%reach b (car ls)))]))])))

;; The primary's refusal raises before anything is killed, as editing's
;; kills do.
(define (%kill-checked! who view range-of unbalanced)
  (let* ([b (views:buffer view)]
         [range (lambda (p)
                  (let ([r (range-of b p)])
                    (cond
                      [(string? r) r]
                      [(syntax:balanced? b (fxmin (car r) (cdr r)) (fxmax (car r) (cdr r)) "") r]
                      [else unbalanced])))]
         [primary (views:point view)]
         [primary-range (range primary)])
    (when (string? primary-range) (error who primary-range))
    (editing:kill-ranges! view
      (lambda (buffer p)
        (let ([r (if (fx= p primary) primary-range (range p))])
          (if (string? r) (values p p) (values (car r) (cdr r))))))))

(define (%lines-back b p n)
  (let* ([doc (buffers:document b)] [line (fxmax 1 (+ (document:line doc p) n))])
    (let-values ([(start end) (editing:lines-bounds b (document:line-start doc line) #f)]) start)))

(commands:define-command (kill-line [prefix (commands:prefix-argument)])
  "Kills the sexps that start on each cursor's line from the cursor, whole, stopping before the end of the list holding it; a count repeats it; 0 or a negative count kills back to the start of a line, when that text is balanced; C-u kills to the line's end whatever it holds."
  (let* ([view (views:command-view 'strict-balance:kill-line)] [b (views:buffer view)] [n (commands:prefix-number)])
    (cond
      [(not (%lexer? b)) (editing:kill-line (and prefix (commands:prefix-number)))]
      [(%escape? prefix) (editing:kill-line #f)]
      [(<= n 0)
       (%kill-checked! 'strict-balance:kill-line view
         (lambda (b p) (cons p (%lines-back b p n)))
         "the text is not balanced")]
      [else
       (let loop ([k n])
         (when (> k 0)
           (%kill-checked! 'strict-balance:kill-line view (lambda (b p) (cons p (%kill-line-end b p))) %crossing)
           (loop (- k 1))))])))

(commands:define-command (kill-whole-line [prefix (commands:prefix-argument)])
  "Kills each cursor's line with its line break, or the lines editing:kill-whole-line's count gives, when they are balanced."
  (let* ([view (views:command-view 'strict-balance:kill-whole-line)] [b (views:buffer view)] [n (commands:prefix-number)])
    (if (or (%escape? prefix) (not (%lexer? b)))
        (editing:kill-whole-line n)
        (%kill-checked! 'strict-balance:kill-whole-line view
          (lambda (b p)
            (let-values ([(s e) (editing:lines-bounds b p #f)])
              (let-values ([(from to)
                            (cond
                              [(> n 0) (values s (let ([doc (buffers:document b)])
                                                   (let ([last (fx+ (document:line doc p) (fx- n 1))])
                                                     (%after-line-end b (document:line-start doc (fxmin last (document:line doc (fx- (document:length doc) 1))))))))]
                              [(= n 0) (values s e)]
                              [else (values (let ([start (%lines-back b p (+ n 1))]) (fxmax 1 (fx- start 1))) e)])])
                (cons from to))))
          "the line is not balanced"))))

(define (%word-range b p forward?)
  (let ([words (syntax:buffer-word-characters b)] [last (fx- (document:length (buffers:document b)) 1)])
    (define (word? q) (let ([c (%char-at b q)]) (and c (word-char? c words))))
    (define (skipped? q) (let ([c (%char-at b q)]) (and c (%delimiter-char? b c))))
    (let loop ([q p] [from p])
      (cond
        [(if forward? (fx>= q last) (fx<= q 1)) "no word"]
        [(word? (if forward? q (fx- q 1)))
         (cons from (editing:forward-word-position b q (if forward? 1 -1)))]
        [(skipped? (if forward? q (fx- q 1)))
         (let ([next (if forward? (fx+ q 1) (fx- q 1))]) (loop next next))]
        [else (loop (if forward? (fx+ q 1) (fx- q 1)) from)]))))

(define (%whitespace-start b p)
  (let loop ([q p]) (if (memv (%char-at b (fx- q 1)) '(#\space #\tab #\newline)) (loop (fx- q 1)) q)))

(define (%kill-words! who n)
  (let ([view (views:command-view who)])
    (let loop ([k (abs n)])
      (when (> k 0)
        (%kill-checked! who view (lambda (b p) (%word-range b p (> n 0))) %crossing)
        (loop (- k 1))))))

(commands:define-command (kill-word [prefix (commands:prefix-argument)])
  "Kills the next word after each cursor, passing over brackets and quotes without killing them; C-u kills one word whatever it passes."
  (let ([b (views:buffer (views:command-view 'strict-balance:kill-word))])
    (cond
      [(%escape? prefix) (editing:kill-word 1)]
      [(%lexer? b) (%kill-words! 'strict-balance:kill-word (commands:prefix-number))]
      [else (editing:kill-word (commands:prefix-number))])))

(commands:define-command (backward-kill-word [prefix (commands:prefix-argument)])
  "Kills the word before each cursor, passing over brackets and quotes without killing them; after blanks, with editing:backward-kill-word-stops-at-whitespace?, deletes them as editing does; C-u kills one word whatever it passes."
  (let* ([view (views:command-view 'strict-balance:backward-kill-word)] [b (views:buffer view)] [p (views:point view)]
         [n (commands:prefix-number)])
    (cond
      [(%escape? prefix) (editing:backward-kill-word 1)]
      [(not (%lexer? b)) (editing:backward-kill-word n)]
      [(and (= n 1) (editing:backward-kill-word-stops-at-whitespace?)
            (memv (%char-at b (fx- p 1)) '(#\space #\tab #\newline)))
       (for-each
         (lambda (c)
           (let ([p (views:cursor-point c)])
             (unless (syntax:balanced? b (%whitespace-start b p) p "")
               (error 'strict-balance:backward-kill-word %crossing))))
         (views:cursors view))
       (editing:backward-kill-word n)]
      [else (%kill-words! 'strict-balance:backward-kill-word (- n))])))

(commands:define-command (kill-region [prefix (commands:prefix-argument)])
  "Kills each cursor's region when every region is balanced; C-u kills it whatever it holds."
  (let* ([view (views:command-view 'strict-balance:kill-region)] [b (views:buffer view)])
    (unless (or (%escape? prefix) (not (%lexer? b)))
      (editing:check-regions 'strict-balance:kill-region view)
      (%check-regions-balanced 'strict-balance:kill-region view (views:cursors view)))
    (editing:kill-region)))

(commands:define-command (delete-indentation [prefix (commands:prefix-argument)])
  "Joins lines as editing:delete-indentation does, refusing, before any join, one that moves text that is not balanced into or out of a comment."
  (let* ([view (views:command-view 'strict-balance:delete-indentation)] [b (views:buffer view)])
    (when (%lexer? b)
      (for-each
        (lambda (c)
          (for-each
            (lambda (join)
              (unless (syntax:balanced? b (car join) (cdr join) "")
                (error 'strict-balance:delete-indentation %crossing)))
            (editing:join-ranges view (views:cursor-point c) (views:cursor-mark c) prefix)))
        (views:cursors view)))
    (editing:delete-indentation prefix)))

(define (%in-line-comment? b p)
  (let ([l (syntax:string-or-comment-at b p)])
    (and l (%class? l (syntax:class comment)) (syntax:lexeme-open-ended? l) (fx< p (syntax:lexeme-end l)))))

(define (%mode-on? view)
  (and (%lexer? (views:buffer view)) (views:with-view view (mode))))

(define (%refuse-unbalanced-insert! who view text)
  (let ([b (views:buffer view)])
    (for-each
      (lambda (c)
        (unless (syntax:balanced? b (views:cursor-point c) (views:cursor-point c) text)
          (error who %crossing)))
      (views:cursors view))))

;; A line break typed inside a line comment would move the rest of the
;; line out of it; when that text is not balanced the comment goes on on
;; the new line instead, as paredit's RET and C-j do.
(define (%comment-continues? who view)
  (let ([b (views:buffer view)])
    (and (%mode-on? view)
         (not (%escape? (commands:prefix-argument)))
         (let ([unbalanced (filter (lambda (c) (not (syntax:balanced? b (views:cursor-point c) (views:cursor-point c) "\n")))
                                   (views:cursors view))])
           (unless (for-all (lambda (c) (%in-line-comment? b (views:cursor-point c))) unbalanced)
             (error who %crossing))
           (pair? unbalanced)))))

(define (%balanced-newline newline n)
  (let ([view (views:current)])
    (if (and view (views:buffer view) (eq? (commands:this-command) editing:newline)
             (%comment-continues? 'editing:newline view))
        (do ([k 0 (+ k 1)]) ((>= k n)) (comment:indent-new-line))
        (newline n))))

(define (%balanced-open-line open-line n)
  (let ([view (views:current)])
    (when (and view (views:buffer view) (%mode-on? view) (not (%escape? (commands:prefix-argument))))
      (%refuse-unbalanced-insert! 'editing:open-line view "\n"))
    (open-line n)))

(commands:define-command (electric-newline-and-maybe-indent)
  "Breaks the line as editing:electric-newline-and-maybe-indent does, by RET's rule."
  (if (%comment-continues? 'strict-balance:electric-newline-and-maybe-indent
        (views:command-view 'strict-balance:electric-newline-and-maybe-indent))
      (comment:indent-new-line)
      (editing:electric-newline-and-maybe-indent)))

(commands:define-command (newline-and-indent)
  "Breaks the line and indents as editing:newline-and-indent does, by RET's rule."
  (if (%comment-continues? 'strict-balance:newline-and-indent (views:command-view 'strict-balance:newline-and-indent))
      (comment:indent-new-line)
      (editing:newline-and-indent)))

(keys:remap! keymap editing:self-insert self-insert)
(keys:remap! keymap editing:delete-backward-char delete-backward-char)
(keys:remap! keymap editing:delete-char delete-char)
(keys:remap! keymap editing:delete-forward-char delete-forward-char)
(keys:remap! keymap editing:kill-line kill-line)
(keys:remap! keymap editing:kill-whole-line kill-whole-line)
(keys:remap! keymap editing:kill-word kill-word)
(keys:remap! keymap editing:backward-kill-word backward-kill-word)
(keys:remap! keymap editing:kill-region kill-region)
(keys:remap! keymap editing:delete-indentation delete-indentation)
(keys:remap! keymap editing:electric-newline-and-maybe-indent electric-newline-and-maybe-indent)
(keys:remap! keymap editing:newline-and-indent newline-and-indent)
(advice-add! editing:replace-selection? %balanced-selection)
(advice-add! editing:newline %balanced-newline)
(advice-add! editing:open-line %balanced-open-line)
(for-each (lambda (command) (tables:set! commands:region-commands command #t))
          (list kill-region delete-backward-char delete-forward-char))
