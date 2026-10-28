;;; Span trees: one per input item, from the key to the paint (the plan's
;;; stage 2). A recorder builds them from the events the general hooks
;;; announce (plugin.ss wires them); this module knows no hook, so tests
;;; drive it directly.
;;;
;;; A tree starts when its item arrives (or, without a transport that says
;;; so, when the input service takes it) and has these spans under its root:
;;;   queue                        arrival to the input service taking it;
;;;   task NAME                    the task the item started, with
;;;     pre-command-hook, command NAME, post-command-hook (nested for
;;;     commands calling commands) and job KEY for each job started;
;;;   browser: key to send         the page's own duration, start unknown;
;;;   network                      the page's round trip from sending the
;;;                                item to the screen including it arriving,
;;;                                minus the server's time from arrival to
;;;                                writing that screen;
;;;   tab ID                       one branch per tab drawn in the first
;;;                                redisplay after the item's task:
;;;     redraw                     pieces drawn and reused, HTML bytes;
;;;     waiting for the tab        until its page applied the screen before;
;;;     write                      the screen's event, its bytes;
;;;     network and browser        from written to the page saying applied,
;;;       browser: morph, browser: settle, browser: paint
;;;                                the page's own durations.
;;; A branch whose tab's screen did not change ends after its redraw.
;;; Times are milliseconds from the item's arrival on the server's
;;; monotonic clock; spans measured by the page have no start. Each span
;;; counts the bytes allocated and the milliseconds of garbage collection
;;; in the whole process while it was open.
;;;
;;; A tree is finished when its task has ended and every branch is done (its
;;; paint reported, or its screen unchanged), or, once its task has ended,
;;; when nothing has happened to it for the recorder's patience; it is then
;;; handed to the recorder's
;;; writer and forgotten. The recorder is called from the editor thread and
;;; from the transport's threads, so every entry point takes its lock.
prelude: :gerbil/core

(import (only-in :gerbil/runtime/hash HashTable)
        (only-in :std/encoding/json json->string)
        ./clock)
(export span
        span?
        span-name
        span-start
        span-duration
        span-details
        span-children
        item-tree
        item-tree?
        item-tree-sequence
        item-tree-root
        item-tree-complete?
        recorder
        recorder?
        new-recorder
        recorder-trees-in-flight
        recorder-current-label
        recorder-arrived!
        recorder-resolved!
        recorder-task-started!
        recorder-task-finished!
        recorder-command-hook!
        recorder-job-started!
        recorder-job-finished!
        recorder-redraw-started!
        recorder-redraw-finished!
        recorder-screen-ready!
        recorder-screen-sent!
        recorder-screen-applied!
        recorder-expire!
        recorder-flush!
        tree->json)

;;; Spans

;; START and DURATION in milliseconds from the tree's anchor; START is #f
;; for a span the page measured. OPENED is the reading it opened with,
;; until it ends. DETAILS is an alist from symbols to JSON values.
;; CHILDREN are newest first while building.
(defclass span ((name      : :string)
                (start     :? :flonum)
                (duration  :? :flonum)
                (allocated : :flonum)
                (gc        : :flonum)
                (details   : :list)
                (children  : :list)
                (opened    :? reading))
  final: #t)

(def (new-span (name : :string) (start :? :flonum) (opened :? reading)
               details: (details : :list := []))
  => span
  (span name: name start: start duration: #f allocated: 0. gc: 0. details: details
        children: [] opened: opened))

(def (add-child! (parent : span) (child : span)) => span
  (set! parent.children (cons child parent.children))
  child)

(def (add-detail! (s : span) (key : :symbol) (value : :t)) => :void
  (set! s.details (append s.details [(cons key value)])))

;; End S, open since S's reading, at READING, ANCHOR being its tree's.
(def (end-span! (s : span) (r : reading) (anchor : :flonum)) => :void
  (unless s.duration
    (let (opened s.opened)
      (set! s.duration (flmax 0. (fl- (fl- (reading-time r) anchor) (or s.start 0.))))
      (when opened
        (set! s.allocated (flmax 0. (fl- (reading-allocated r) (reading-allocated opened))))
        (set! s.gc (flmax 0. (fl- (reading-gc r) (reading-gc opened)))))
      (set! s.opened #f))))

;; A span the page measured: DURATION milliseconds, with no start.
(def (browser-span (name : :string) (duration : :flonum)) => span
  (span name: name start: #f duration: duration allocated: 0. gc: 0. details: [] children: [] opened: #f))

;;; Trees

;; One tab's branch of a tree. ROUND-SCREEN is the revision of the screen
;; made ready for it after the tree's redraw, SENT its (stream . count)
;; once written.
(defclass branch ((client   : :t)
                  (top      : span)         ; the tab's span
                  (redraw   :? span)
                  (ready-at :? :flonum)
                  (revision :? :fixnum)
                  (sent     :? :pair)
                  (sent-at  :? :flonum)
                  (shown    :? span)        ; network and browser
                  (done?    : :boolean))
  final: #t)

;; ANCHOR is the arrival's monotonic time in ms; ROUND the redisplay it was
;; drawn in (#f before); STACK the open spans of its task, innermost first.
(defclass item-tree ((client    : :t)
                     (tab       : :string)
                     (sequence  : :fixnum)
                     (item      : :list)      ; alist describing the item
                     (wall      : :real)      ; seconds since the epoch at arrival
                     (anchor    : :flonum)
                     (root      : span)
                     (task      :? span)
                     (task-id   :? :fixnum)
                     (task-done? : :boolean)
                     (stack     : :list)
                     (round     :? :fixnum)
                     (branches  : :list)
                     (last      : :flonum)    ; when anything last happened to it
                     (ended     : :flonum)    ; when its last stage on the server ended
                     (complete? : :boolean))
  final: #t)

(def (tree-ms (tree : item-tree) (r : reading)) => :flonum
  (fl- (reading-time r) tree.anchor))

;; Something happened to TREE at NOW, a stage on the server's clock.
(def (touch! (tree : item-tree) (now : :flonum)) => :void
  (set! tree.last now)
  (set! tree.ended (flmax tree.ended now)))

;;; The recorder

;; IN-FLIGHT: (client . sequence) -> tree. TASKS: task id -> tree. JOBS:
;; job id -> (tree . span). CURRENT: the tree whose task is next to start.
;; ROUND: the redisplay counter; ROUND-CLIENTS, the clients drawn in it;
;; ROUND-OPEN?: whether the next redraw belongs to it. SENT: client ->
;; ((stream . count) . ms) of its latest screens written; APPLIED: client
;; -> ms its page last confirmed a screen. FINISH: called with each
;; finished tree, outside the lock. PATIENCE: ms after which a tree that
;; nothing happens to is finished incomplete. CURRENT-LABEL: the item a
;; sample is taken during, for the sampler.
(defclass recorder ((lock        : :mutex)
                    (in-flight   : HashTable)
                    (tasks       : HashTable)
                    (jobs        : HashTable)
                    (current     :? item-tree)
                    (round       : :fixnum)
                    (round-clients : :list)
                    (round-open? : :boolean)
                    (sent        : HashTable)
                    (applied     : HashTable)
                    (finish      : :procedure)
                    (patience    : :flonum)
                    (current-label :? :string))
  final: #t)

(def (new-recorder finish: (finish : :procedure) patience: (patience : :flonum := 10000.)) => recorder
  (recorder lock: (make-mutex 'profiler) in-flight: (make-hash-table) tasks: (make-hash-table-eqv)
            jobs: (make-hash-table-eqv) current: #f round: 0 round-clients: [] round-open?: #f
            sent: (make-hash-table-eq) applied: (make-hash-table-eq)
            finish: finish patience: patience current-label: #f))

;; The trees being followed, for tests.
(def (recorder-trees-in-flight (self : recorder)) => :list
  (with-lock self.lock (lambda () (hash-values self.in-flight))))

;; Call THUNK holding SELF's lock, then hand the trees it returns, a list,
;; to SELF's finish procedure.
(def (with-recorder (self : recorder) (thunk : :procedure)) => :void
  (let (finished (with-lock self.lock thunk))
    (for-each self.finish finished)))

(def (tree-key (client : :t) (sequence : :fixnum)) => :pair
  (cons client sequence))

(def (new-tree (self : recorder) (client : :t) (tab : :string) (sequence : :fixnum) (item : :list) (r : reading))
  => item-tree
  (let* ((root (new-span "input" 0. r details: item))
         (tree (item-tree client: client tab: tab sequence: sequence item: item
                          wall: (time->seconds (current-time)) anchor: (reading-time r) root: root
                          task: #f task-id: #f task-done?: #f stack: [] round: #f branches: []
                          last: (reading-time r) ended: (reading-time r) complete?: #f)))
    (hash-put! self.in-flight (tree-key client sequence) tree)
    tree))

;; The tree's label for samples taken while its task runs.
(def (tree-label (tree : item-tree)) => :string
  (string-append "item " tree.tab "#" (number->string tree.sequence)
                 (let (key (assq 'key tree.item)) (if key (string-append " " (cdr key)) ""))))

;; Item ITEM (an alist describing it) numbered SEQUENCE arrived from
;; CLIENT, whose tab is TAB.
(def (recorder-arrived! (self : recorder) (client : :t) (tab : :string) (sequence : :fixnum) (item : :list))
  => :void
  (let (r (take-reading))
    (with-recorder self (lambda () (new-tree self client tab sequence item r) []))))

;; The input service took item SEQUENCE of CLIENT, starting the task NAME
;; (#f for none).
(def (recorder-resolved! (self : recorder) (client : :t) (tab : :string) (sequence : :fixnum) (item : :list)
                         (name :? :symbol))
  => :void
  (let (r (take-reading))
    (with-recorder self
      (lambda ()
        (set! self.round-open? #f)
        (let* ((tree (or (hash-get self.in-flight (tree-key client sequence))
                         (new-tree self client tab sequence item r)))
               (queue (add-child! (item-tree-root tree) (new-span "queue" 0. #f))))
          (set! (span-duration queue) (tree-ms tree r))
          (add-detail! (item-tree-root tree) 'command (if name (symbol->string name) #f))
          (touch! tree (reading-time r))
          (if name
            (set! self.current tree)
            (begin
              (set! self.current #f)
              (set! (item-tree-task-done? tree) #t)))
          [])))))

;; Task ID named NAME started; it is the current tree's when one waits.
(def (recorder-task-started! (self : recorder) (id : :fixnum) (name : :symbol)) => :void
  (let (r (take-reading))
    (with-recorder self
      (lambda ()
        (set! self.round-open? #f)
        (let (tree self.current)
          (when tree
            (using (tree : item-tree)
              (set! self.current #f)
              (let (task (add-child! tree.root (new-span (string-append "task " (symbol->string name))
                                                        (tree-ms tree r) r)))
                (set! tree.task task)
                (set! tree.task-id id)
                (set! tree.stack [task])
                (touch! tree (reading-time r))
                (set! self.current-label (tree-label tree))
                (hash-put! self.tasks id tree)))))
        []))))

;; Task ID ended HOW.
(def (recorder-task-finished! (self : recorder) (id : :fixnum) (how : :symbol)) => :void
  (let (r (take-reading))
    (with-recorder self
      (lambda ()
        (let (tree (hash-get self.tasks id))
          (if tree
            (using (tree : item-tree)
              (hash-remove! self.tasks id)
              (set! self.current-label #f)
              (for-each (lambda ((s : span)) (end-span! s r tree.anchor)) tree.stack)
              (set! tree.stack [])
              (add-detail! (:- tree.task span) 'ended (symbol->string how))
              (set! tree.task-done? #t)
              (touch! tree (reading-time r))
              (finished-trees self [tree]))
            []))))))

;; A command hook's edge, in task ID: WHICH is pre-command or
;; post-command, EDGE first or last (the recorder's callbacks run first
;; and last on each hook), COMMAND the command running.
(def (recorder-command-hook! (self : recorder) (id :? :fixnum) (which : :symbol) (edge : :symbol)
                             (command :? :symbol))
  => :void
  (let (r (take-reading))
    (with-recorder self
      (lambda ()
        (let (tree (and id (hash-get self.tasks id)))
          (when tree
            (using (tree : item-tree)
              (let* ((open (lambda ((name : :string))
                             (let (s (add-child! (car tree.stack) (new-span name (tree-ms tree r) r)))
                               (set! tree.stack (cons s tree.stack)))))
                     (close (lambda ()
                              (when (fx> (length tree.stack) 1)
                                (end-span! (car tree.stack) r tree.anchor)
                                (set! tree.stack (cdr tree.stack))))))
                (case which
                  ((pre-command)
                   (if (eq? edge 'first)
                     (open "pre-command-hook")
                     (begin
                       (close)
                       (open (string-append "command " (if command (symbol->string command) "?"))))))
                  ((post-command)
                   (if (eq? edge 'first)
                     (begin (close) (open "post-command-hook"))
                     (close))))
                (touch! tree (reading-time r))))))
        []))))

(def (printed (value : :t)) => :string
  (let (text (call-with-output-string "" (lambda (port) (write value port))))
    (if (fx> (string-length text) 80) (string-append (substring text 0 80) "…") text)))

;; Job ID keyed KEY started, during task TASK (#f for none).
(def (recorder-job-started! (self : recorder) (task :? :fixnum) (id : :fixnum) (key : :t)) => :void
  (let (r (take-reading))
    (with-recorder self
      (lambda ()
        (let (tree (and task (hash-get self.tasks task)))
          (when tree
            (using (tree : item-tree)
              (let (s (add-child! (car tree.stack)
                                  (new-span (string-append "job " (printed key)) (tree-ms tree r) r)))
                (hash-put! self.jobs id (cons tree s))))))
        []))))

;; Job ID ended HOW.
(def (recorder-job-finished! (self : recorder) (id : :fixnum) (how : :symbol)) => :void
  (let (r (take-reading))
    (with-recorder self
      (lambda ()
        (let (found (hash-get self.jobs id))
          (when found
            (hash-remove! self.jobs id)
            (using ((tree (car found) : item-tree) (s (cdr found) : span))
              (end-span! s r tree.anchor)
              (add-detail! s 'ended (symbol->string how)))))
        []))))

;; The trees a redraw for CLIENT belongs to: those whose task has started
;; or that started none, not drawn yet or drawn in this round, without a
;; branch for CLIENT. Call with the lock held.
(def (redraw-trees (self : recorder) (client : :t)) => :list
  (filter (lambda ((tree : item-tree))
            (and (or tree.task tree.task-done?)
                 (or (not tree.round) (fx= tree.round self.round))
                 (not (find (lambda ((b : branch)) (eq? b.client client)) tree.branches))))
          (hash-values self.in-flight)))

(def (tab-name (client : :t) (tab : :string)) => :string
  (string-append "tab " tab))

;; The renderer started drawing CLIENT's screen (TAB names it).
(def (recorder-redraw-started! (self : recorder) (client : :t) (tab : :string)) => :void
  (let (r (take-reading))
    (with-recorder self
      (lambda ()
        (when (or (not self.round-open?) (memq client self.round-clients))
          (set! self.round (fx1+ self.round))
          (set! self.round-clients [])
          (set! self.round-open? #t))
        (set! self.round-clients (cons client self.round-clients))
        (for-each (lambda ((tree : item-tree))
                    (set! tree.round self.round)
                    (let* ((top (add-child! tree.root (new-span (tab-name client tab) (tree-ms tree r) r)))
                           (redraw (add-child! top (new-span "redraw" (tree-ms tree r) r))))
                      (set! tree.branches
                        (cons (branch client: client top: top redraw: redraw ready-at: #f revision: #f
                                      sent: #f sent-at: #f shown: #f done?: #f)
                              tree.branches))
                      (touch! tree (reading-time r))))
                  (redraw-trees self client))
        []))))

;; The branches of this round's trees for CLIENT. Call with the lock held.
(def (round-branches (self : recorder) (client : :t)) => :list
  (filter-map (lambda ((tree : item-tree))
                (and tree.round (fx= tree.round self.round)
                     (let (b (find (lambda ((b : branch)) (eq? b.client client)) tree.branches))
                       (and b (cons tree b)))))
              (hash-values self.in-flight)))

;; The renderer drew CLIENT's screen: DRAWN pieces drawn, REUSED reused,
;; BYTES of HTML.
(def (recorder-redraw-finished! (self : recorder) (client : :t) (drawn : :fixnum) (reused : :fixnum)
                                (bytes : :fixnum))
  => :void
  (let (r (take-reading))
    (with-recorder self
      (lambda ()
        (for-each (lambda ((found : :pair))
                    (using ((tree (car found) : item-tree) (b (cdr found) : branch))
                      (let (redraw b.redraw)
                        (when (and redraw (not (span-duration redraw)))
                          (end-span! redraw r tree.anchor)
                          (add-detail! redraw 'drawn drawn)
                          (add-detail! redraw 'reused reused)
                          (add-detail! redraw 'bytes bytes)))))
                  (round-branches self client))
        []))))

;; CLIENT's new screen is REVISION, or #f when unchanged, including its
;; input up to THROUGH.
(def (recorder-screen-ready! (self : recorder) (client : :t) (revision :? :fixnum) (through : :fixnum))
  => :void
  (let (r (take-reading))
    (with-recorder self
      (lambda ()
        (let (trees
              (map (lambda ((found : :pair))
                     (using ((tree (car found) : item-tree) (b (cdr found) : branch))
                       (unless (or b.ready-at b.done?)
                         (set! b.ready-at (tree-ms tree r))
                         (if revision
                           (set! b.revision revision)
                           (begin
                             (add-detail! b.top 'screen "unchanged")
                             (end-span! b.top r tree.anchor)
                             (set! b.done? #t)))
                         (touch! tree (reading-time r)))
                       tree))
                   (round-branches self client)))
          (finished-trees self trees))))))

;; CLIENT's screen REVISION was written as COUNT on STREAM, BYTES of it.
(def (recorder-screen-sent! (self : recorder) (client : :t) (stream : :fixnum) (count : :fixnum)
                            (revision : :fixnum) (bytes : :fixnum))
  => :void
  (let (r (take-reading))
    (with-recorder self
      (lambda ()
        (let ((now (reading-time r))
              (applied (hash-get self.applied client)))
          (hash-put! self.sent client
                     (cons (cons (cons stream count) now)
                           (let (old (hash-ref self.sent client []))
                             (if (fx> (length old) 31) (list-head* old 31) old))))
          (hash-for-each
           (lambda (key (tree : item-tree))
             (for-each
              (lambda ((b : branch))
                (when (and (eq? b.client client) b.revision (not b.sent) (fx<= b.revision revision))
                  (let* ((ready b.ready-at)
                         (waited-until (flmax (:- ready :flonum)
                                              (if applied (fl- (:- applied :flonum) tree.anchor) 0.)))
                         (written-at (fl- now tree.anchor))
                         (wait (add-child! b.top (new-span "waiting for the tab" ready #f)))
                         (write (add-child! b.top (new-span "write" (flmin waited-until written-at) #f
                                                            details: [(cons 'bytes bytes)
                                                                      (cons 'revision revision)]))))
                    (set! (span-duration wait) (flmax 0. (fl- (flmin waited-until written-at) ready)))
                    (set! (span-duration write) (flmax 0. (fl- written-at (flmin waited-until written-at))))
                    (set! b.sent (cons stream count))
                    (set! b.sent-at written-at)
                    (touch! tree now))))
              tree.branches))
           self.in-flight)
          [])))))

(def (list-head* (l : :list) (n : :fixnum)) => :list
  (if (or (fxzero? n) (null? l)) [] (cons (car l) (list-head* (cdr l) (fx1- n)))))

;; The server's time, in ms of its clock, when CLIENT's screen COUNT of
;; STREAM was written, or #f. Call with the lock held.
(def (sent-time (self : recorder) (client : :t) (stream : :fixnum) (count : :fixnum)) => (Maybe :flonum)
  (let (found (assoc (cons stream count) (hash-ref self.sent client [])))
    (and found (cdr found))))

(def (measured (measurements : :list) (name : :symbol)) => :t
  (let (pair (assq name measurements))
    (and pair (cdr pair))))

;; CLIENT's page reported MEASUREMENTS (the web contract's alist) of its
;; screen COUNT on STREAM.
(def (recorder-screen-applied! (self : recorder) (client : :t) (stream : :fixnum) (count : :fixnum)
                               (measurements : :list))
  => :void
  (let (r (take-reading))
    (with-recorder self
      (lambda ()
        (let ((now (reading-time r))
              (confirmed? (measured measurements 'revision))
              (morph (measured measurements 'morph))
              (settle (measured measurements 'settle))
              (painted (measured measurements 'painted))
              (touched []))
          (when confirmed?
            (hash-put! self.applied client now))
          (hash-for-each
           (lambda (key (tree : item-tree))
             (for-each
              (lambda ((b : branch))
                (when (eq? b.client client)
                  ;; This screen applied.
                  (when (and confirmed? (equal? b.sent (cons stream count)) (not b.shown))
                    (let (shown (add-child! b.top (new-span "network and browser" b.sent-at #f)))
                      (set! (span-duration shown) (flmax 0. (fl- (fl- now tree.anchor) (:- b.sent-at :flonum))))
                      (when morph (add-child! shown (browser-span "browser: morph" morph)))
                      (when settle (add-child! shown (browser-span "browser: settle" settle)))
                      (set! b.shown shown)
                      (touch! tree now)
                      (set! touched (cons tree touched))))
                  ;; Earlier screens painted: a report names the page's
                  ;; paints by stream and count.
                  (let (paint (and b.shown (not b.done?) b.sent
                                   (find (lambda ((p : :list)) (equal? b.sent (cons (car p) (cadr p))))
                                         (or painted []))))
                    (when paint
                      (let (ms (caddr paint))
                        (add-child! (:- b.shown span) (browser-span "browser: paint" ms))
                        (let (to-screen (assq 'key-to-screen (span-details tree.root)))
                          (when (and to-screen (eq? client tree.client))
                            (add-detail! tree.root 'key-to-paint (fl+ (cdr to-screen) ms)))))
                      (end-span! b.top r tree.anchor)
                      (set! (span-duration b.top)
                        (fl- (fl+ (:- b.sent-at :flonum) (:- (span-duration (:- b.shown span)) :flonum))
                             (:- (span-start b.top) :flonum)))
                      (set! b.done? #t)
                      ;; Not a stage of the server: the root ends where it did.
                      (set! tree.last now)
                      (set! touched (cons tree touched))))))
              tree.branches))
           self.in-flight)
          ;; The page's own inputs this screen is the first to include.
          (for-each
           (lambda ((entry : :list))
             (match entry
               ([sequence to-send to-received]
                (let (tree (hash-get self.in-flight (tree-key client sequence)))
                  (when tree
                    (using (tree : item-tree)
                      (when to-send
                        (add-child! tree.root (browser-span "browser: key to send" to-send)))
                      (let* ((written (sent-time self client stream count))
                             (server (and written (fl- written tree.anchor))))
                        (when server
                          (let (network (browser-span "network" (flmax 0. (fl- to-received server))))
                            (add-detail! network 'round-trip to-received)
                            (add-detail! network 'server server)
                            (add-child! tree.root network)))
                        (add-detail! tree.root 'key-to-screen
                                     (fl+ (or to-send 0.) (fl+ to-received (fl+ (or morph 0.) (or settle 0.))))))
                      (touch! tree now)
                      (set! touched (cons tree touched))))))
               (else (void))))
           (or (measured measurements 'keys) []))
          (finished-trees self touched))))))

;; Whether TREE is finished: its task ended and every branch is done.
(def (tree-finished? (tree : item-tree)) => :boolean
  (and tree.task-done?
       (pair? tree.branches)
       (andmap branch-done? tree.branches)))

;; Those of TREES that are finished, taken out of SELF and closed. Call
;; with the lock held.
(def (finished-trees (self : recorder) (trees : :list)) => :list
  (let lp ((rest trees) (out []))
    (match rest
      ([] out)
      ([tree . more]
       (if (and (tree-finished? tree) (eq? (hash-get self.in-flight (tree-key (item-tree-client tree) (item-tree-sequence tree))) tree))
         (begin
           (close-tree! self tree #t)
           (lp more (cons tree out)))
         (lp more out))))))

;; Take TREE out of SELF and end what is still open. Call with the lock held.
(def (close-tree! (self : recorder) (tree : item-tree) (complete? : :boolean)) => :void
  (hash-remove! self.in-flight (tree-key tree.client tree.sequence))
  (when tree.task-id (hash-remove! self.tasks tree.task-id))
  (when (eq? self.current tree) (set! self.current #f))
  (set! tree.complete? complete?)
  ;; The root lasts to the item's last stage on the server's clock; jobs
  ;; still running and branches not done end there too, marked unfinished.
  (let ((root tree.root)
        (end (make-reading tree.ended 0. 0.)))
    (end-span! root (take-reading) tree.anchor)
    (set! (span-duration root) (fl- tree.ended tree.anchor))
    (end-open! root end tree.anchor)))

(def (end-open! (s : span) (end : reading) (anchor : :flonum)) => :void
  (for-each (lambda ((child : span)) (end-open! child end anchor)) s.children)
  (unless s.duration
    (set! s.opened #f)
    (add-detail! s 'unfinished #t)
    (set! s.duration (flmax 0. (fl- (fl- (reading-time end) anchor) (or s.start 0.))))))

;; Finish every tree whose task has ended and that nothing has happened to
;; for SELF's patience: its reports were lost, or a tab closed.
(def (recorder-expire! (self : recorder)) => :void
  (let (now (now-ms))
    (with-recorder self
      (lambda ()
        (let (stale (filter (lambda ((tree : item-tree))
                              ;; Waiting in the queue or in a long task is
                              ;; the lag being measured: only a tree whose
                              ;; task ended, waiting for reports, expires.
                              (and tree.task-done? (fl> (fl- now tree.last) self.patience)))
                            (hash-values self.in-flight)))
          (for-each (lambda (tree) (close-tree! self tree #f)) stale)
          stale)))))

;; Finish every tree, as the recorder stops.
(def (recorder-flush! (self : recorder)) => :void
  (with-recorder self
    (lambda ()
      (let (all (hash-values self.in-flight))
        (for-each (lambda ((tree : item-tree)) (close-tree! self tree (tree-finished? tree))) all)
        all))))

;;; JSON

(def (round3 (x : :flonum)) => :flonum
  (fl/ (flround (fl* x 1000.)) 1000.))

(def (span->json (s : span)) => HashTable
  (let (h (make-hash-table))
    (hash-put! h "name" s.name)
    (hash-put! h "start" (if s.start (round3 s.start) (void)))
    (hash-put! h "duration" (if s.duration (round3 s.duration) (void)))
    (hash-put! h "allocated" (inexact->exact (flround s.allocated)))
    (hash-put! h "gc" (round3 s.gc))
    (let (details (make-hash-table))
      (for-each (lambda ((pair : :pair))
                  (let (v (cdr pair))
                    (hash-put! details (symbol->string (car pair))
                               (cond ((flonum? v) (round3 v)) ((not v) (void)) (else v)))))
                s.details)
      (hash-put! h "details" details))
    (hash-put! h "children"
               ;; Children oldest first; those the page measured, which have
               ;; no start, after the others.
               (map span->json
                    (list-sort (lambda ((a : span) (b : span))
                                 (cond ((and a.start b.start) (fl< a.start b.start))
                                       (else (and a.start #t))))
                               (reverse s.children))))
    h))

;; TREE as one line of JSON (no newline).
(def (tree->json (tree : item-tree)) => :string
  (let (h (make-hash-table))
    (hash-put! h "tab" tree.tab)
    (hash-put! h "sequence" tree.sequence)
    (hash-put! h "arrived" (inexact->exact (flround (fl* 1000. (exact->inexact tree.wall)))))
    (hash-put! h "complete" tree.complete?)
    (hash-put! h "span" (span->json tree.root))
    (:- (json->string h) :string)))
