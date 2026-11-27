#!tuna
(import (minibuffer) (completion) (buffers) (commands) (document) (editing) (faces) (jobs) (jump-history) (keys)
        (views) (line-picker lines) (options) (tables) (saved))

(saved:define-saved goto-line-history '() (lambda (v) (and (list? v) (for-all string? v))))

(options:define-option start-from-top? #f boolean?
  "When true, M-s l lists lines from the first; otherwise from point's line, wrapping. C-u M-s l does the other for one read.")

(completion:define-category line-category "Lines of the current buffer, valued by the line's start.")

(jobs:define-worker (%split-lines input emit receive)
  (import (document) (line-picker lines))
  (let-values ([(doc atoms first from-top?) (apply values input)])
    (let ([last (last-line doc)])
      (define (emit-lines! from to)
        (let loop ([k from] [atoms (atoms-from atoms (document:line-start doc from))])
          (when (fx<= k to)
            (let ([upto (fxmin to (fx+ k 999))])
              (let-values ([(lines atoms) (line-candidates doc atoms k upto)])
                (let ([kept (non-blank lines)])
                  (unless (fx= (vector-length kept) 0) (emit kept)))
                (loop (fx+ upto 1) atoms))))))
      (if from-top?
          (emit-lines! 1 last)
          (let ([first (fxmin first last)])
            (emit-lines! first last)
            (emit-lines! 1 (fx- first 1)))))))

;; A line whose candidate holds an atom's text maps characters to
;; positions one to one only before the atom, so its row draws plain and
;; the read lands at the leftmost match before the atom, or at the
;; line's start.
(define (%line-source view from-top?)
  (let* ([b (views:buffer view)] [doc (buffers:document b)] [version (buffers:version b)] [point (views:point view)]
         [point-line (document:line doc point)] [atoms (buffers:atom-texts doc 0 (document:length doc))]
         [width (string-length (number->string (last-line doc)))] [chars (document:unit characters)])
    (define total (document:offset doc (document:length doc) chars))
    (define (position-after p n)
      (let ([o (fx+ (document:offset doc p chars) n)]) (and (fx<= o total) (document:position doc o chars))))
    (define (now p) (or (buffers:map-position b p version) p))
    (define (faces text p)
      (let ([at (buffers:map-position b p version)] [current (buffers:document b)] [n (string-length text)])
        (if (not at)
            '()
            (let ([base (document:offset current at chars)])
              (if (fx> (fx+ base n) (document:offset current (document:length current) chars))
                  '()
                  (let ([end (document:position current (fx+ base n) chars)])
                    (if (not (string=? (document:text current at end) text))
                        '()
                        (let ([offset (lambda (q) (fx- (document:offset current (fxmax at (fxmin end q)) chars) base))])
                          (fold-right
                            (lambda (layer acc)
                              (append (map (lambda (s) (list (offset (car s)) (offset (cadr s)) (caddr s)))
                                           (buffers:spans layer at end))
                                      acc))
                            '() (buffers:layers b))))))))))
    (define (prefix text p)
      (let* ([line (document:line doc p)] [digits (number->string line)])
        (cons (if (fx< line point-line) faces:warning faces:shadow)
              (string-append (make-string (fx- width (string-length digits)) #\space) digits))))
    (define (lookup p spans)
      (let* ([atom (let ([after (atoms-from atoms p)]) (and (pair? after) (caar after)))]
             [ranges (fold-right
                       (lambda (s acc)
                         (let ([from (position-after p (car s))] [to (position-after p (cadr s))])
                           (if (or (not to) (and atom (fx< atom to))) acc (cons (list (now from) (now to)) acc))))
                       '() (list-sort (lambda (a b) (fx< (car a) (car b))) spans))])
        (cons (if (null? ranges) (now p) (caar ranges)) ranges)))
    (define (preview place)
      (if place
          (begin
            (completion:preview-place view b (car place) (cdr place))
            (parameterize ([jump-history:place-ranges (and (pair? (cdr place)) (cdr place))])
              (jump-history:after-jump view)))
          (begin
            (completion:end-preview-place)
            (views:set-point! view point))))
    (completion:source
      (job %split-lines (list doc atoms point-line from-top?))
      (in-order)
      (category line-category)
      (faces faces)
      (prefix prefix)
      (lookup lookup)
      (preview preview (lambda (chosen) (preview #f))))))

(define (%read-line)
  (let ([from-top? (if (commands:prefix-argument) (not (start-from-top?)) (start-from-top?))])
    (completion:read "Go to line: " (list (%line-source (views:current) from-top?)))))

(commands:define-command (line [place (%read-line)])
  "Moves point to PLACE, a pair of a position and the buffer ranges of the matches there, as M-s l reads it from the current buffer: the first match's start on the line chosen, or the line's start. Records the place point left in jump-history, then calls jump-history:after-jump with the matches as the place's ranges."
  (unless (and (pair? place) (fixnum? (car place)))
    (assertion-violation 'line-picker:line "not a position and its matches" place))
  (let* ([view (views:current)] [left (views:point view)])
    (views:set-point! view (car place))
    (jump-history:push! (views:buffer view) left)
    (parameterize ([jump-history:place-ranges (and (pair? (cdr place)) (cdr place))])
      (jump-history:after-jump view))))

(define (%read-line-number)
  (let* ([view (views:current)] [current (document:line (buffers:document (views:buffer view)) (views:point view))])
    (minibuffer:read-number (string-append "Go to line (default " (number->string current) "): ")
                            goto-line-history current)))

;; As in Emacs, C-u alone is not a line number, so the line is read.
(define (%goto-line-argument)
  (let ([p (commands:prefix-argument)])
    (if (and p (not (pair? p))) (commands:prefix-number) (%read-line-number))))

(commands:define-command (goto-line [line (%goto-line-argument)])
  "Moves point to the start of line LINE of the current view's buffer, counting from 1; a line past the last goes to the end. Records the place point left in jump-history when point moves, then calls jump-history:after-jump."
  (unless (and (integer? line) (exact? line))
    (assertion-violation 'line-picker:goto-line "not an exact integer" line))
  (let* ([view (views:current)] [left (views:point view)])
    (views:set-point! view (editing:line-position (views:buffer view) line))
    (unless (fx= (views:point view) left)
      (jump-history:push! (views:buffer view) left view))
    (jump-history:after-jump view)))

(tables:set! completion:category-default-styles line-category (list completion:substring))
(keys:bind! keys:global "M-s l" line)
(keys:bind! keys:global "M-g g" goto-line)
(keys:bind! keys:global "M-g M-g" goto-line)
