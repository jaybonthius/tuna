#!tuna
(import (diagnostics) (completion) (jump-history) (projects) (files) (buffers) (document) (views) (layout) (commands) (keys))

(define (%line-and-column d)
  (let ([b (diagnostics:diagnostic-buffer d)] [start (diagnostics:diagnostic-start d)])
    (if b
        (let* ([doc (buffers:document b)] [line (document:line doc start)] [chars (document:unit characters)])
          (cons line (fx- (document:offset doc start chars) (document:offset doc (document:line-start doc line) chars))))
        start)))

(define (%name d)
  (let ([b (diagnostics:diagnostic-buffer d)])
    (if b (buffers:name b) (let ([path (diagnostics:diagnostic-path d)]) (substring path (fx+ (%last-slash path) 1) (string-length path))))))

(define (%last-slash path)
  (let loop ([i (fx- (string-length path) 1)])
    (if (char=? (string-ref path i) #\/) i (loop (fx- i 1)))))

;; A diagnostic of a buffer that visits no file has no location to
;; preview, so it is valued by itself.
(define (%value d)
  (let ([path (diagnostics:diagnostic-path d)])
    (if path
        (let ([lc (%line-and-column d)]) (cons* path (car lc) (cdr lc)))
        d)))

(define (%source title narrow ds preview)
  (completion:source
    (candidates
      (list->vector
        (map (lambda (d)
               (cons (format "~a:~a: ~a" (%name d) (car (%line-and-column d)) (diagnostics:text d)) (%value d)))
             ds)))
    (in-order)
    (title title)
    (narrow narrow)
    (category (and preview completion:location-category))
    (preview (and preview (car preview)) (and preview (cdr preview)))))

(define (%read-diagnostic)
  (let* ([ds (if (commands:prefix-argument)
                 (let ([project (projects:find (files:directory))])
                   (unless project
                     (error 'diagnostic-picker:diagnostic "The buffer is in no project"))
                   (diagnostics:under (projects:root project)))
                 (diagnostics:in (buffers:current)))]
         [preview (and (for-all diagnostics:diagnostic-path ds)
                       (let-values ([(show end) (completion:location-preview (views:current) jump-history:after-jump)])
                         (cons show end)))]
         [of (lambda (severity) (filter (lambda (d) (eq? (diagnostics:diagnostic-severity d) severity)) ds))]
         [by-value (map (lambda (d) (cons (%value d) d)) ds)])
    (when (null? ds)
      (error 'diagnostic-picker:diagnostic "No diagnostics"))
    (let ([chosen (completion:read "Go to diagnostic: "
                    (filter values
                      (map (lambda (severity title narrow)
                             (let ([these (of severity)])
                               (and (pair? these) (%source title narrow these preview))))
                           '(error warning info hint) '("Errors" "Warnings" "Infos" "Hints") '(#\e #\w #\i #\h))))])
      (cdr (assoc chosen by-value)))))

(commands:define-command (diagnostic [d (%read-diagnostic)])
  "Goes to D, read from the current buffer's diagnostics, or with C-u from its project's, and records the place point left in jump-history."
  (unless (diagnostics:diagnostic? d)
    (assertion-violation 'diagnostic-picker:diagnostic "not a diagnostic" d))
  (let* ([view (layout:selected-view)] [left (views:buffer view)] [at (views:point view)]
         [b (or (diagnostics:diagnostic-buffer d) (files:visit (diagnostics:diagnostic-path d)))])
    (layout:switch-to-buffer b)
    (let ([view (layout:selected-view)] [start (diagnostics:diagnostic-start d)])
      (views:set-point! view (if (pair? start) (%line-position b start) start))
      (jump-history:push! left at)
      (jump-history:after-jump view))))

;; Visiting the file makes its path diagnostics the buffer's, so a line
;; and column is left only for one the visit dropped as empty.
(define (%line-position b lc)
  (let ([doc (buffers:document b)])
    (document:line-start doc (fxmin (car lc) (document:line doc (document:length doc))))))

(keys:bind! keys:global "M-g f" diagnostic)
