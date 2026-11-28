#!tuna
(import (completion) (buffers) (commands) (editing) (keys) (views) (layout) (files) (options) (saved))

(saved:define-saved buffer-history '() (lambda (v) (and (list? v) (for-all string? v))))

(define (%current-buffer)
  (let ([v (views:current)]) (and v (views:buffer v))))

(define (buffers display-view)
  (unless (or (not display-view) (procedure? display-view))
    (assertion-violation 'buffer-picker:buffers "neither a procedure nor #f" display-view))
  (let* ([current (%current-buffer)] [shown #f]
         [live (remp (lambda (b) (or (eq? b current) (buffers:internal-name? (buffers:name b)))) (buffers:all))]
         [on-screen (map views:buffer (layout:views))]
         [ordered (append (remp (lambda (b) (memq b on-screen)) live)
                          (filter (lambda (b) (memq b on-screen)) live)
                          (if (and current (not (buffers:internal-name? (buffers:name current))))
                              (list current)
                              '()))])
    (completion:source
      (candidates (list->vector (map (lambda (b) (cons (buffers:name b) b)) ordered)))
      (in-order)
      (title "Buffers")
      (narrow #\b)
      (category completion:buffer-category)
      (preview (and display-view (lambda (b)
                                   (cond
                                     [b (set! shown (display-view b)) (views:preview-buffer! shown b)]
                                     [shown (views:end-preview! shown)])))
               (and display-view (lambda (chosen) (when shown (views:end-preview! shown))))))))

(options:define-option sources (list (lambda (display-view) (buffers #f))) (lambda (v) (and (list? v) (for-all procedure? v)))
  "Procedures called by buffer-picker:switch-to-buffer, each returning a source, with the procedure layout:call-with-display-view gives, of a buffer, that returns the view the switch shows it in; buffer-picker:buffers given it previews there.")

(define read-buffer
  (case-lambda
    [(question) (read-buffer question buffer-history #f)]
    [(question h) (read-buffer question h #f)]
    [(question h default)
     (unless (or (not default) (buffers:buffer? default))
       (assertion-violation 'buffer-picker:read-buffer "neither a buffer nor #f" default))
     (completion:read question (list (buffers #f)) h (and default (buffers:name default)))]))

(define (%read-switch)
  (layout:call-with-display-view
    (lambda (display-view)
      (let ([v (completion:read-or-input "Switch to buffer: " (map (lambda (p) (p display-view)) (sources)) buffer-history)])
        (cond
          [(or (buffers:buffer? v) (pair? v)) v]
          [else (or (buffers:find v) (buffers:make v ""))])))))

(define (%location? v)
  (and (pair? v) (string? (car v)) (pair? (cdr v)) (integer? (cadr v)) (exact? (cadr v))
       (integer? (cddr v)) (exact? (cddr v)) (>= (cddr v) 0)))

(commands:define-command (switch-to-buffer [target (%read-switch)])
  "Shows TARGET in the selected view: a buffer, or a location, a path, a line number and a column, whose file it visits there."
  (cond
    [(buffers:buffer? target) (layout:switch-to-buffer target)]
    [(%location? target)
     (let ([b (files:visit (car target))])
       (layout:switch-to-buffer b)
       (views:set-point! (layout:selected-view) (editing:line-position b (cadr target) (cddr target))))]
    [else (assertion-violation 'buffer-picker:switch-to-buffer "neither a buffer nor a location" target)]))

(commands:define-command (switch-to-buffer-other-view)
  "Reads a buffer or a location as buffer-picker:switch-to-buffer does, under layout:display-in-other-view as the overriding action, so the read previews in the view the choice then shows in, another view, which it selects."
  (layout:call-with-overriding-action layout:display-in-other-view (lambda () (switch-to-buffer (%read-switch)))))

(commands:define-command (kill-buffer [buffer (read-buffer "Kill buffer: " buffer-history (%current-buffer))])
  "Kills BUFFER."
  (buffers:kill! buffer)
  (void))

(keys:bind! keys:global "C-x b" switch-to-buffer)
(keys:bind! keys:global "C-x 4 b" switch-to-buffer-other-view)
(keys:bind! keys:global "C-x k" kill-buffer)
(keys:bind! completion:buffer-action-keymap "b" switch-to-buffer)
(keys:bind! completion:buffer-action-keymap "k" kill-buffer)
