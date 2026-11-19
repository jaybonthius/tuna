#!tuna
(import (minibuffer) (completion) (buffers) (commands) (document) (jobs) (keys) (views) (line-picker lines))

(define-saved goto-line-history '() (lambda (v) (and (list? v) (for-all string? v))))

(completion:define-category line-category "Lines of the current buffer, valued by the line's start.")

(jobs:define-worker (%split-lines input emit receive)
  (import (document) (line-picker lines))
  (let* ([doc (car input)] [last (last-line doc)])
    (let loop ([k 1] [atoms (cdr input)])
      (when (fx<= k last)
        (let ([to (fxmin last (fx+ k 999))])
          (let-values ([(lines atoms) (line-candidates doc atoms k to)])
            (emit lines)
            (loop (fx+ to 1) atoms)))))))

;; Matches the main thread's limit, so a buffer that completion would match
;; there is split there too.
(define (%small? doc)
  (and (fx<= (document:length doc) 50000) (fx<= (document:line doc (fx- (document:length doc) 1)) 1000)))

(define (%read-line)
  (let* ([view (views:current)] [doc (buffers:document (views:buffer view))] [point (views:point view)]
         [atoms (buffers:atom-texts doc 0 (document:length doc))])
    (completion:read "Go to line: "
      (list (if (%small? doc)
                (completion:source
                  (candidates (let-values ([(lines rest) (line-candidates doc atoms 1 (last-line doc))]) lines))
                  (in-order)
                  (category line-category)
                  (preview (lambda (p) (views:set-point! view (or p point)))))
                (completion:source
                  (job %split-lines (cons doc atoms))
                  (in-order)
                  (category line-category)
                  (preview (lambda (p) (views:set-point! view (or p point))))))))))

(commands:define-command (line [position (%read-line)])
  "Moves point to POSITION, the start of a line read from the current buffer."
  (views:set-point! (views:current) position))

(define (%read-line-number)
  (let* ([view (views:current)]
         [current (number->string (document:line (buffers:document (views:buffer view)) (views:point view)))]
         [question (string-append "Go to line (default " current "): ")])
    (let loop ([complaint #f])
      (let* ([answer (minibuffer:call-with-setup
                       (lambda (p) (when complaint (minibuffer:message! p complaint)))
                       (lambda () (minibuffer:read question goto-line-history current)))]
             [n (string->number answer 10)])
        (if (and n (exact? n) (integer? n)) n (loop "Please enter a number"))))))

;; As in Emacs, C-u alone is not a line number, so the line is read.
(define (%goto-line-argument)
  (let ([p (commands:prefix-argument)])
    (if (and p (not (pair? p))) (commands:prefix-number) (%read-line-number))))

(commands:define-command (goto-line [line (%goto-line-argument)])
  "Moves point to the start of line LINE of the current view's buffer, counting from 1; a line past the last goes to the end."
  (unless (and (integer? line) (exact? line))
    (assertion-violation 'line-picker:goto-line "not an exact integer" line))
  (let* ([view (views:current)] [doc (buffers:document (views:buffer view))] [end (document:length doc)])
    (views:set-point! view (if (> line (document:line doc end)) end (document:line-start doc (max line 1))))))

(table-set! completion:category-default-styles line-category (list completion:substring))
(keys:bind! keys:global "M-s l" line)
(keys:bind! keys:global "M-g g" goto-line)
(keys:bind! keys:global "M-g M-g" goto-line)
