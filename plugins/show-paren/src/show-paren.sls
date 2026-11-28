#!tuna
(import (syntax) (buffers) (document) (views) (layout) (modes) (web) (ask) (commands) (keys) (hooks) (options) (tables))

(define %self (current-owner))

(modes:define-minor-mode mode
  "Whether the bracket beside each cursor is highlighted with its match."
  (default #t))

(options:define-option when-point-inside-paren #f boolean?
  "Whether an opening bracket right before the cursor, or a closing one right after it, is highlighted.")

(options:define-option when-point-in-periphery #f boolean?
  "Whether a cursor in a line's leading or trailing blanks highlights the bracket at that end of the line's text.")

(options:define-option message-on-close #t boolean?
  "Whether typing a closing bracket says what it matches when the highlight cannot show it.")

;; At priority 0, above syntax's bracket spans (-5), so a highlight is
;; drawn inside a bracket's colour; keyed by view, so each view shows the
;; matches of its own cursors.
(buffers:define-layer highlights (priority 0))

(define %match '((face . show-paren.match)))
(define %mismatch '((face . show-paren.mismatch)))

(define (%class? lexeme class) (eq? (syntax:lexeme-class lexeme) class))

(define (%bracket? l) (and l (or (%class? l (syntax:class open)) (%class? l (syntax:class close))) l))

(define (%blank? t) (memv t '(#\space #\tab)))

(define (%periphery doc p)
  (let* ([line (document:line doc p)] [start (document:line-start doc line)]
         [last (fx- (document:length doc) 1)]
         [end (let loop ([q p]) (let ([t (and (fx< q last) (document:token doc q))]) (if (and (char? t) (not (char=? t #\newline))) (loop (fx+ q 1)) q)))]
         [text-start (let loop ([q start]) (if (and (fx< q end) (%blank? (document:token doc q))) (loop (fx+ q 1)) q))]
         [text-end (let loop ([q end]) (if (and (fx> q text-start) (%blank? (document:token doc (fx- q 1)))) (loop (fx- q 1)) q))])
    (cond
      [(fx= text-start text-end) (values #f #f)]
      [(fx<= p text-start) (values text-start text-end)]
      [(fx>= p text-end) (values #f text-end)]
      [else (values #f #f)])))

(define (%bracket-at b p)
  (or (let ([l (syntax:lexeme-ending-at b p)]) (and l (%class? l (syntax:class close)) l))
      (let ([l (syntax:lexeme-starting-at b p)]) (and l (%class? l (syntax:class open)) l))
      (and (when-point-inside-paren)
           (or (let ([l (syntax:lexeme-ending-at b p)]) (and l (%class? l (syntax:class open)) l))
               (let ([l (syntax:lexeme-starting-at b p)]) (and l (%class? l (syntax:class close)) l))))
      (and (when-point-in-periphery)
           (let-values ([(text-start text-end) (%periphery (buffers:document b) p)])
             (or (and text-start (%bracket? (syntax:lexeme-starting-at b text-start)))
                 (and text-end (%bracket? (syntax:lexeme-ending-at b text-end))))))))

(define (%mismatched? l match)
  (or (not match)
      (syntax:lexeme-mismatched? (if (%class? l (syntax:class close)) l match))))

(define (%spans-of view)
  (let ([b (views:buffer view)])
    (fold-left
      (lambda (spans c)
        (let ([l (%bracket-at b (views:cursor-point c))])
          (if l
              (let* ([match (syntax:match b l)] [value (if (%mismatched? l match) %mismatch %match)])
                (append spans
                        (cons (list (syntax:lexeme-start l) (syntax:lexeme-end l) value)
                              (if match (list (list (syntax:lexeme-start match) (syntax:lexeme-end match) value)) '()))))
              spans)))
      '() (views:cursors view))))

(define (%shows? view)
  (let ([b (views:buffer view)])
    (and b (syntax:lexer (modes:major-mode b)) (views:with-view view (mode)))))

;; What each view was given at the last batch, so a view that changed its
;; buffer, or whose mode went off, has its spans taken back.
(define %drawn '())

(define (%clear! entry)
  (let ([b (cadr entry)])
    (when (buffers:live? b)
      (buffers:set-spans! (caddr entry) 0 (document:length (buffers:document b)) '()))))

(define (%update!)
  (let ([now (map (lambda (view)
                    (let ([b (views:buffer view)])
                      (list view b (buffers:layer b highlights view)
                            (sort (lambda (x y) (fx< (car x) (car y))) (%spans-of view)))))
                  (filter %shows? (layout:views)))])
    (for-each
      (lambda (old)
        (let ([new (assq (car old) now)])
          (unless (and new (eq? (cadr new) (cadr old)))
            (%clear! old))))
      %drawn)
    (for-each
      (lambda (entry)
        (let ([old (assq (car entry) %drawn)])
          (unless (and old (eq? (cadr old) (cadr entry)) (equal? (cadddr old) (cadddr entry)))
            (buffers:set-spans! (caddr entry) 0 (document:length (buffers:document (cadr entry))) (cadddr entry)))))
      now)
    (set! %drawn now)))

(define (%closing-char? b char)
  (exists (lambda (pair) (char=? (cdr pair) char)) (syntax:mode-bracket-pairs (modes:major-mode b))))

(define (%line-text doc position)
  (let* ([line (document:line doc position)] [start (document:line-start doc line)]
         [end (if (fx< line (document:line doc (fx- (document:length doc) 1)))
                  (fx- (document:line-start doc (fx+ line 1)) 1)
                  (fx- (document:length doc) 1))])
    (buffers:text-between doc start end)))

(define (%message-on-close command)
  (let* ([view (views:current)] [b (and view (views:buffer view))] [char (keys:typed-char)])
    (when (and b char (syntax:lexer (modes:major-mode b)) (%closing-char? b char)
               (views:with-view view (and (mode) (message-on-close))))
      (let ([l (syntax:lexeme-ending-at b (views:point view))])
        (when (and l (%class? l (syntax:class close)))
          (let ([match (syntax:match b l)])
            (cond
              [(not match) (ask:message "No matching bracket")]
              [(syntax:lexeme-mismatched? l) (ask:message "Mismatched brackets")]
              [(fx< (syntax:lexeme-start match) (views:top view (web:current-client)))
               (ask:message (string-append "Matches " (%line-text (buffers:document b) (syntax:lexeme-start match))))])))))))

(advice-add! batch-ended
  (lambda (ended)
    (call-as-owner %self %update!)
    (ended)))

(hooks:add! commands:after-command %message-on-close)
(tables:set! web:stylesheets 'show-paren "show-paren/show-paren.css")
(on-unload (lambda () (for-each %clear! %drawn) (set! %drawn '())))
