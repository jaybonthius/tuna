#!tuna
(import (files) (file-watch) (buffers) (document) (views) (modes) (hooks) (options) (timers) (ask))

(modes:define-minor-mode mode
  "Whether the buffer is watched and reloaded when its source changes."
  (default #t)
  (on-change (lambda (on?) (%follow-buffers!))))

(define %stale-marks (make-weak-eq-hashtable))

(modes:define-minor-mode stale?
  "Whether the buffer's file changed on disk under unsaved edits, which are kept."
  (state args
    (let ([b (if (null? args) (buffers:current) (car args))])
      (and (buffers:buffer? b) (eq-hashtable-contains? %stale-marks b))))
  (lighter "Stale"))

(define (%seconds? v) (and (real? v) (positive? v) (finite? v)))

(options:define-option verbose? #t boolean?
  "When true, a reload tells the echo area so.")

(options:define-option use-notify? #t boolean?
  "When false, no buffer is watched, and every buffer is checked every auto-revert:interval seconds."
  (lambda (v) (%follow-buffers!)))

(options:define-option interval 5 %seconds?
  "Seconds between checks of the buffers no watch serves."
  (lambda (v) (%restart-polling!)))

(options:define-option non-file-buffers? #f boolean?
  "Whether a buffer that visits no file and has a buffers:stale-function is reverted, by its buffers:revert-function, when that says it is stale."
  (lambda (v) (%follow-buffers!)))

(define %followed (make-weak-eq-hashtable))
(define %checking (make-weak-eq-hashtable))
(define %poller #f)

(define (%source-path b) (or (files:path b) (files:directory b)))

;; A temporary visit, as a picker's preview, is no visit to follow until a
;; visit completes it.
(define (%wanted? b)
  (and (buffers:live? b)
       (buffers:with-buffer b (mode))
       (if (files:path b)
           (not (files:temporary? b))
           (and (non-file-buffers?) (buffers:with-buffer b (buffers:stale-function)) #t))))

(define (%polled? b)
  (let ([followed (eq-hashtable-ref %followed b #f)])
    (and followed (not (and (car followed) (file-watch:active? (car followed)))))))

(define (%poll!)
  (for-each (lambda (b) (when (%polled? b) (%check-soon! b)))
            (vector->list (hashtable-keys %followed))))

(define (%update-polling!)
  (let ([needed (exists %polled? (vector->list (hashtable-keys %followed)))])
    (cond
      [(and needed (not %poller)) (set! %poller (timers:run-after (interval) %poll! (interval)))]
      [(and (not needed) %poller) (timers:cancel! %poller) (set! %poller #f)])))

(define (%restart-polling!)
  (when %poller
    (timers:cancel! %poller)
    (set! %poller #f))
  (%update-polling!))

(define (%clear-stale! b)
  (eq-hashtable-delete! %stale-marks b))

(define (%unfollow! b)
  (let ([followed (eq-hashtable-ref %followed b #f)])
    (when followed
      (eq-hashtable-delete! %followed b)
      (when (car followed) (file-watch:unwatch! (car followed)))
      (%clear-stale! b)
      (%update-polling!))))

(define (%reported b)
  (lambda (entry kind)
    (when (eq? kind 'stopped) (%update-polling!))
    (%check-soon! b)))

(define (%follow! b)
  (if (%wanted? b)
      (let ([path (%source-path b)] [followed (eq-hashtable-ref %followed b #f)])
        (unless (and followed (string=? path (cdr followed)) (eq? (and (car followed) #t) (use-notify?)))
          (%unfollow! b)
          (eq-hashtable-set! %followed b (cons (and (use-notify?) (file-watch:watch! path (%reported b))) path))
          (%update-polling!)
          (%check-soon! b)))
      (%unfollow! b)))

(define (%follow-buffers!)
  (for-each %follow! (buffers:all)))

(define (%end b) (- (document:length (buffers:document b)) 1))

(define (%say-stale b)
  (ask:message (format "~a changed on disk; unsaved edits kept" (buffers:name b))))

;; So a view of a log being written follows it, as Emacs's does.
(define (%check-file! b)
  (let ([at-end (filter (lambda (v) (= (views:point v) (%end b))) (views:showing b))])
    (let-values ([(reloaded left) (files:revert-changed-buffers (lambda (x) (eq? x b)))])
      (cond
        [(memq b left)
         (unless (eq-hashtable-contains? %stale-marks b)
           (eq-hashtable-set! %stale-marks b #t)
           (%say-stale b))]
        [(memq b reloaded)
         (for-each (lambda (v) (when (eq? (views:buffer v) b) (views:set-point! v (%end b)))) at-end)
         (when (verbose?) (ask:message (format "Reverted ~a" (buffers:name b))))]
        [else (%clear-stale! b)]))))

(define (%check-other! b)
  (let ([stale-function (buffers:with-buffer b (buffers:stale-function))])
    (when (and stale-function (stale-function b) (buffers:live? b))
      (buffers:with-buffer b (buffers:revert-buffer))
      (when (verbose?) (ask:message (format "Reverted ~a" (buffers:name b)))))))

(define (%check! b)
  (when (and (buffers:live? b) (eq-hashtable-contains? %followed b))
    (if (files:path b) (%check-file! b) (%check-other! b))))

;; A burst of reports must not read the file once for each.
(define (%check-soon! b)
  (if (eq-hashtable-contains? %checking b)
      (eq-hashtable-set! %checking b 'again)
      (begin
        (eq-hashtable-set! %checking b 'running)
        (spawn-task
          (lambda (restore)
            (let loop ()
              (guard (c [(cancelled? c) (eq-hashtable-delete! %checking b) (raise c)] [#t (report c)])
                (%check! b))
              (if (eq? (eq-hashtable-ref %checking b #f) 'again)
                  (begin
                    (eq-hashtable-set! %checking b 'running)
                    (loop))
                  (eq-hashtable-delete! %checking b))))))))

(define (check buffer)
  (unless (and (buffers:buffer? buffer) (buffers:live? buffer))
    (assertion-violation 'auto-revert:check "not a live buffer" buffer))
  (%check! buffer))

(define (%path-changed! b old new) (%follow! b))

(hooks:add! files:after-visit %follow!)
(hooks:add! files:visited-path-changed %path-changed!)
(hooks:add! files:after-revert %clear-stale!)
(hooks:add! files:after-save %clear-stale!)
(hooks:add! modes:major-mode-changed %follow!)
(hooks:add! buffers:killed %unfollow!)
(%follow-buffers!)
