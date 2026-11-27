#!tuna
(import (completion) (buffers) (commands) (editing) (keys) (views) (layout) (files) (options) (saved))

(saved:define-saved buffer-history '() (lambda (v) (and (list? v) (for-all string? v))))

(define (%current-buffer)
  (let ([v (views:current)]) (and v (views:buffer v))))

(define (%buffer-preview view)
  (lambda (b)
    (if b (views:preview-buffer! view b) (views:end-preview! view))))

(define (buffers view)
  (unless (or (not view) (views:view? view))
    (assertion-violation 'buffer-picker:buffers "neither a view nor #f" view))
  (let* ([current (%current-buffer)]
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
      (preview (and view (%buffer-preview view)) (and view (lambda (chosen) (views:end-preview! view)))))))

(options:define-option sources (list (lambda (view) (buffers #f))) (lambda (v) (and (list? v) (for-all procedure? v)))
  "Procedures of a view, called by buffer-picker:switch-to-buffer with the view it switches, each returning a source; buffer-picker:buffers given that view previews in it.")

(define read-buffer
  (case-lambda
    [(question) (read-buffer question buffer-history #f)]
    [(question h) (read-buffer question h #f)]
    [(question h default)
     (unless (or (not default) (buffers:buffer? default))
       (assertion-violation 'buffer-picker:read-buffer "neither a buffer nor #f" default))
     (completion:read question (list (buffers #f)) h (and default (buffers:name default)))]))

(define (%read-switch)
  (let* ([view (views:current)]
         [v (completion:read-or-input "Switch to buffer: " (map (lambda (p) (p view)) (sources)) buffer-history)])
    (cond
      [(or (buffers:buffer? v) (pair? v)) v]
      [else (or (buffers:find v) (buffers:make v ""))])))

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

(commands:define-command (switch-to-buffer-other-view [target (%read-switch)])
  "Shows TARGET, as buffer-picker:switch-to-buffer does, in another view, which it selects."
  (layout:call-with-overriding-action layout:display-in-other-view (lambda () (switch-to-buffer target))))

(commands:define-command (kill-buffer [buffer (read-buffer "Kill buffer: " buffer-history (%current-buffer))])
  "Kills BUFFER."
  (buffers:kill! buffer)
  (void))

(keys:bind! keys:global "C-x b" switch-to-buffer)
(keys:bind! keys:global "C-x 4 b" switch-to-buffer-other-view)
(keys:bind! keys:global "C-x k" kill-buffer)
(keys:bind! completion:buffer-action-keymap "b" switch-to-buffer)
(keys:bind! completion:buffer-action-keymap "k" kill-buffer)
