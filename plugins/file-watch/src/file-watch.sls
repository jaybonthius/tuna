#!tuna
(import (jobs) (options) (inotify))

(define %self (current-owner))

(define (%positive-seconds? v) (and (real? v) (positive? v) (finite? v)))

(options:define-option delay 0.1 %positive-seconds?
  "Seconds without an event after which a burst of events is reported."
  (lambda (v) (%send-timing!)))

(options:define-option longest-burst 0.5 %positive-seconds?
  "Seconds after which a burst that never goes quiet is reported anyway, and a new one starts."
  (lambda (v) (%send-timing!)))

(define %events
  (inotify-flags close-write modify create moved-to delete moved-from delete-self only-directory))

(jobs:define-worker (%watcher input emit receive)
  (import (inotify))
  (let ([ino (descriptors->inotify (vector-ref input 0) (vector-ref input 1))])
    (define (now)
      (let ([t (current-time 'time-monotonic)])
        (+ (time-second t) (/ (time-nanosecond t) 1e9))))
    (define (kind-of e)
      (let ([flags (inotify-event-flags e)])
        (define (any? . names) (exists (lambda (name) (enum-set-member? name flags)) names))
        (cond
          [(any? 'queue-overflow) 'unknown]
          [(any? 'delete-self 'ignored) 'stopped]
          [(any? 'close-write 'modify) 'changed]
          [(any? 'create 'moved-to) 'created]
          [(any? 'delete 'moved-from) 'deleted]
          [else #f])))
    ;; A deletion and then a creation is what a program that saves by
    ;; deleting and creating shows, so it is a change; a file created and
    ;; then written is still new.
    (define (merged before after)
      (cond
        [(and (eq? before 'deleted) (eq? after 'created)) 'changed]
        [(and (eq? before 'created) (eq? after 'changed)) 'created]
        [else after]))
    ;; A burst may name thousands of entries, as a checkout does, so they
    ;; are kept in a table, with the order each was first seen.
    (define kinds (make-hashtable equal-hash equal?))
    (define (add-event! e order)
      (let ([kind (kind-of e)])
        (if kind
            (let* ([key (if (eq? kind 'unknown)
                            (cons -1 #f)
                            (cons (inotify-event-watch e) (and (not (eq? kind 'stopped)) (inotify-event-name e))))]
                   [seen (hashtable-ref kinds key #f)])
              (hashtable-set! kinds key (if seen (merged seen kind) kind))
              (if seen order (cons key order)))
            order)))
    (define (batch! order)
      (let ([items (map (lambda (key) (list (car key) (cdr key) (hashtable-ref kinds key #f))) (reverse order))])
        (hashtable-clear! kinds)
        items))
    (define (run)
      (let loop ([delay (vector-ref input 2)] [longest (vector-ref input 3)] [order '()] [first #f] [last #f])
        (let ([due (and first (min (+ last delay) (+ first longest)))] [t (now)])
          (if (and due (>= t due))
              (begin
                (emit (batch! order))
                (loop delay longest '() #f #f))
              (begin
                (inotify-wait ino (and due (- due t)))
                (let take ([delay delay] [longest longest])
                  (let ([message (receive 0)])
                    (cond
                      [(eof-object? message)
                       (let ([events (inotify-read ino)])
                         (if (null? events)
                             (loop delay longest order first last)
                             (let ([t (now)])
                               (loop delay longest (fold-left (lambda (order e) (add-event! e order)) order events)
                                     (or first t) t))))]
                      [(eq? message 'stop) (void)]
                      [else (take (vector-ref message 0) (vector-ref message 1))]))))))))
    (dynamic-wind void run (lambda () (inotify-close! ino)))))

(define-record-type (%watch %make-watch watch?)
  (sealed #t)
  (fields path* folder entry handler owner (mutable descriptor) (mutable ended?) (mutable exists?)))

(define-record-type %instance
  (sealed #t)
  (fields inotify (mutable job)))

(define %main-thread (get-thread-id))

(define %current #f)
(define %folders (make-eqv-hashtable))
(define %by-owner (make-eq-hashtable))
(define %calls '())
(define %calling? #f)

(define (%check-main-thread who)
  (unless (fx= (get-thread-id) %main-thread)
    (assertion-violation who "not on the main thread")))

(define (%check-watch who w)
  (unless (watch? w)
    (assertion-violation who "not a watch" w)))

(define (%join folder name)
  (if (char=? (string-ref folder (fx- (string-length folder) 1)) #\/)
      (string-append folder name)
      (string-append folder "/" name)))

(define (%without-final-slash path)
  (let ([n (string-length path)])
    (if (and (fx> n 1) (char=? (string-ref path (fx- n 1)) #\/)) (substring path 0 (fx- n 1)) path)))

;; One task runs the handlers, so they keep the order of their events, and
;; a handler that pauses holds back the ones after it.
(define (%queue-call! w entry kind)
  (set! %calls (cons (list w entry kind) %calls))
  (unless %calling?
    (set! %calling? #t)
    (spawn-task
      (lambda (restore)
        (let drain ()
          (if (null? %calls)
              (set! %calling? #f)
              (let ([calls (reverse %calls)])
                (set! %calls '())
                (for-each
                  (lambda (call)
                    (let ([w (car call)])
                      (unless (%watch-ended? w)
                        (guard (c [(cancelled? c) (raise c)] [(unloaded? c) (void)] [#t (report c)])
                          (call-as-owner (%watch-owner w)
                            (lambda () ((%watch-handler w) (cadr call) (caddr call))))))))
                  calls)
                (drain))))))))

;; A program that saves by renaming a new file over the watched one shows
;; only its creation, so a creation of a file that was there is a change.
(define (%entry-kind w kind)
  (let ([kind (if (and (eq? kind 'created) (%watch-exists? w)) 'changed kind)])
    (%watch-exists?-set! w (not (eq? kind 'deleted)))
    kind))

(define (%folder-stopped! descriptor)
  (let ([watches (hashtable-ref %folders descriptor '())])
    (hashtable-delete! %folders descriptor)
    (for-each (lambda (w)
                (%watch-descriptor-set! w #f)
                (%queue-call! w (%watch-path* w) 'stopped))
              watches)
    (%end-instance-if-unused!)))

(define (%deliver! batch)
  (for-each
    (lambda (item)
      (let ([descriptor (car item)] [name (cadr item)] [kind (caddr item)])
        (case kind
          [(unknown)
           (for-each (lambda (w) (%queue-call! w (%watch-path* w) 'unknown))
                     (apply append (vector->list (hashtable-values %folders))))]
          [(stopped) (%folder-stopped! descriptor)]
          [else
           (for-each
             (lambda (w)
               (cond
                 [(not (%watch-entry w))
                  (when name (%queue-call! w (%join (%watch-folder w) name) kind))]
                 [(equal? name (%watch-entry w))
                  (%queue-call! w (%watch-path* w) (%entry-kind w kind))]))
             (hashtable-ref %folders descriptor '()))])))
    batch))

(define (%start-instance!)
  (let ([ino (open-inotify)])
    (guard (c [#t (inotify-close! ino) (raise c)])
      (let-values ([(fd wake) (inotify-descriptors ino)])
        (let ([instance (make-%instance ino #f)])
          (call-as-owner %self
            (lambda ()
              (%instance-job-set! instance
                (guard (c [#t (inotify-close! (descriptors->inotify fd wake)) (raise c)])
                  (jobs:start %watcher (vector fd wake (delay) (longest-burst))
                    (lambda (batch) (when (eq? instance %current) (%deliver! batch)))
                    (lambda (ended)
                      (when (eq? instance %current)
                        (set! %current #f)
                        (inotify-close! ino)
                        (vector-for-each %folder-stopped! (hashtable-keys %folders)))))))))
          instance)))))

;; A refused instance, as at the user's instance limit or the process's
;; descriptor limit, makes every watch inactive, so its caller polls, as
;; for a watch the kernel refuses.
(define (%instance!)
  (or %current
      (begin
        (set! %current (guard (c [(error? c) #f]) (%start-instance!)))
        %current)))

;; The job may be blocked waiting for events, so each message comes with a
;; wake; the wake comes second, so the message is there when the job wakes.
(define (%tell! instance message)
  (jobs:send! (%instance-job instance) message)
  (inotify-wake! (%instance-inotify instance)))

(define (%send-timing!)
  (when %current
    (%tell! %current (vector (delay) (longest-burst)))))

;; A cancel landing before the stop is told would leave a job no one tells
;; to stop, and the main thread's instance open.
(define (%end-instance!)
  (let ([instance %current])
    (when instance
      (call-with-cancellation-masked
        (lambda (restore)
          (set! %current #f)
          (%tell! instance 'stop)
          (inotify-close! (%instance-inotify instance)))))))

(define (%end-instance-if-unused!)
  (when (fx= (hashtable-size %folders) 0)
    (%end-instance!)))

;; One unload action for each owner, not one for each watch, since an
;; owner may make and end thousands.
(define (%remember! w)
  (let ([owner (%watch-owner w)])
    (unless (hashtable-contains? %by-owner owner)
      (on-unload
        (lambda ()
          (let ([watches (hashtable-ref %by-owner owner #f)])
            (hashtable-delete! %by-owner owner)
            (when watches (vector-for-each unwatch! (hashtable-keys watches))))))
      (hashtable-set! %by-owner owner (make-eq-hashtable)))
    (eq-hashtable-set! (hashtable-ref %by-owner owner #f) w #t)))

(define (%forget! w)
  (let ([watches (hashtable-ref %by-owner (%watch-owner w) #f)])
    (when watches (eq-hashtable-delete! watches w))))

;; A watch the kernel refuses, as when the folder is missing or the user's
;; watch limit is reached, is made inactive, so its caller can poll.
(define (%add! instance folder)
  (and instance
       (guard (c [(i/o-error? c) #f])
         (inotify-add-watch! (%instance-inotify instance) folder %events))))

;; A cancel landing part way through watch! or unwatch! would leave a
;; kernel watch, an instance or a job that no table records, which nothing
;; would end.
(define (watch! path handler)
  (unless (string? path)
    (assertion-violation 'file-watch:watch! "not a string" path))
  (unless (and (fx> (string-length path) 0) (char=? (string-ref path 0) #\/))
    (assertion-violation 'file-watch:watch! "not an absolute path" path))
  (unless (procedure? handler)
    (assertion-violation 'file-watch:watch! "not a procedure" handler))
  (%check-main-thread 'file-watch:watch!)
  (call-with-cancellation-masked
    (lambda (restore)
      (let* ([plain (%without-final-slash path)]
             [folder? (file-directory? plain)]
             [folder (if folder? plain (let ([p (path-parent plain)]) (if (string=? p "") "/" p)))]
             [instance (%instance!)]
             [descriptor (%add! instance folder)]
             [w (%make-watch path folder (and (not folder?) (path-last plain)) handler (current-owner)
                             descriptor #f (and (not folder?) (file-exists? plain)))])
        (if descriptor
            (begin
              (hashtable-update! %folders descriptor (lambda (watches) (cons w watches)) '())
              (%remember! w))
            (%end-instance-if-unused!))
        w))))

(define (unwatch! w)
  (%check-watch 'file-watch:unwatch! w)
  (%check-main-thread 'file-watch:unwatch!)
  (call-with-cancellation-masked
    (lambda (restore)
      (unless (%watch-ended? w)
        (%watch-ended?-set! w #t)
        (%forget! w)
        (let ([descriptor (%watch-descriptor w)])
          (when descriptor
            (%watch-descriptor-set! w #f)
            (let ([others (remq w (hashtable-ref %folders descriptor '()))])
              (if (null? others)
                  (begin
                    (hashtable-delete! %folders descriptor)
                    ;; The kernel may have ended the watch already, as when
                    ;; the folder went and the report has not arrived.
                    (when %current
                      (guard (c [(error? c) (void)])
                        (inotify-remove-watch! (%instance-inotify %current) descriptor)))
                    (%end-instance-if-unused!))
                  (hashtable-set! %folders descriptor others)))))))))

(define (active? w)
  (%check-watch 'file-watch:active? w)
  (and (%watch-descriptor w) (not (%watch-ended? w)) #t))

(define (path w)
  (%check-watch 'file-watch:path w)
  (%watch-path* w))

(on-unload %end-instance!)

(record-writer (record-type-descriptor %watch)
  (lambda (w p wr) (fprintf p "#<watch ~a>" (%watch-path* w))))
