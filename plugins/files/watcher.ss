;;; Watching files on the local disk for changes by other programs (the
;;; files plan, stage 3), for the local-disk provider.
;;;
;;; A source (tuna/lib/background) on its own thread watches the folder of
;;; each watched file with Linux inotify, since a watch on the file itself
;;; dies when another program saves by writing a new file and renaming it
;;; over the old one, and keeps only the events about watched names. After
;;; an event it waits until the folder has been quiet for 100 ms (at most
;;; half a second), so a save that makes several events is looked at once.
;;; A folder it cannot watch (the watch limit, a file system without
;;; inotify, or inotify turned off) is polled every few seconds instead;
;;; when the kernel's event queue overflows, every watched file is looked at
;;; again, as it is when asked (recheck-watched!).
;;;
;;; What the thread reports for a file is its size, identity and a SHA-256
;;; of its bytes, or that it is missing, so a file whose modification time
;;; changed but whose bytes did not (touch, a git checkout of the same
;;; contents) is no change, and the editor thread hears only of real ones.
;;; A file that went missing is looked at again 300 ms later before it is
;;; reported, because a program that saves by deleting and creating the
;;; file makes it missing for a moment.
prelude: :gerbil/core

(import (only-in :gerbil/runtime/hash HashTable)
        (only-in :std/crypto/digest sha256)
        (only-in :std/encoding/hex hex-encode hex-decode)
        (only-in :std/os/device device-close)
        :std/os/inotify
        :tuna/kernel
        :tuna/lib/jobs
        :tuna/lib/background
        :tuna/plugins/files/contract)
(export watcher new-watcher watch-path! unwatch-path! recheck-watched!)

;; The paths watched are shared with the source's thread under LOCK, with
;; RECHECK?; the rest belongs to the editor thread.
(defclass watcher ((lock      : :mutex)
                   (paths     : :list)          ; under LOCK: the watched paths, oldest first
                   (recheck?  : :boolean)       ; under LOCK: look at every path again
                   (ctx       : context)
                   (stat      : :procedure)     ; path -> Maybe file-stat, on any thread
                   (read      : :procedure)     ; path -> bytes, on any thread
                   (options   : :procedure)     ; -> (use-inotify? . poll-seconds), on the baton
                   (callbacks : HashTable)      ; path -> procedure of the file's hash
                   (reported  : HashTable)      ; path -> the summary last reported
                   (job       :? :t))
  final: #t)

;; A watcher whose source belongs to CTX's plugin, looking at files with
;; STAT and READ. OPTIONS says, when watching starts, whether to use inotify
;; and how often to poll.
(def (new-watcher (ctx : context) (stat : :procedure) (read : :procedure) (options : :procedure)) => watcher
  (watcher lock: (make-mutex 'tuna-file-watcher) paths: [] recheck?: #f
           ctx: ctx stat: stat read: read options: options
           callbacks: (make-hash-table) reported: (make-hash-table) job: #f))

;; Call (CHANGED HASH) on the baton soon after PATH changed, HASH being
;; the SHA-256 of its bytes, or #f when it is not a readable file. Call on
;; the baton.
(def (watch-path! (w : watcher) (path : :string) (changed : :procedure)) => :void
  (hash-put! w.callbacks path changed)
  (do-with-lock w.lock
    (unless (member path w.paths)
      (set! w.paths (append w.paths [path]))))
  (unless w.job
    (let (options (w.options))
      (set! w.job (context-start-source! w.ctx 'file-watcher
                                         every: 0.01
                                         read: (watching-reader w (car options) (cdr options))
                                         apply: (lambda (reading) (apply-reading! w reading)))))))

;; Stop watching PATH; with nothing left to watch, the source stops. Call
;; on the baton.
(def (unwatch-path! (w : watcher) (path : :string)) => :void
  (hash-remove! w.callbacks path)
  (hash-remove! w.reported path)
  (let (left (do-with-lock w.lock
               (set! w.paths (filter (lambda ((p : :string)) (not (string=? p path))) w.paths))
               w.paths))
    (when (and (null? left) w.job)
      (job-cancel! w.job)
      (set! w.job #f))))

;; Look at every watched path again soon. Callable from any thread.
(def (recheck-watched! (w : watcher)) => :void
  (do-with-lock w.lock (set! w.recheck? #t)))

;; On the baton: call the callbacks of the paths whose summary changed.
(def (apply-reading! (w : watcher) (reading : :list)) => :void
  (for-each (lambda ((entry : :pair))
              (let* ((path (car entry))
                     (summary (cdr entry))
                     (changed (hash-get w.callbacks path)))
                (when (and changed
                           (not (and (hash-key? w.reported path)
                                     (equal? (hash-get w.reported path) summary))))
                  (hash-put! w.reported path summary)
                  (with-catch (lambda (e)
                                (message (string-append "Checking " path " failed: " (exception-summary e))))
                              (lambda ()
                                (changed (and (pair? summary) (string? (cadddr summary))
                                              (hex-decode (cadddr summary)))))))))
            reading))

;;; The source's thread

(def watch-mask
  (fxior IN_CLOSE_WRITE IN_MOVED_TO IN_MOVED_FROM IN_CREATE IN_DELETE IN_ATTRIB
         IN_DELETE_SELF IN_MOVE_SELF IN_ONLYDIR))

;; How long the thread waits for events before it looks for new paths, a
;; recheck or its cancellation.
(def idle-seconds .5)
(def quiet-seconds .1)
(def longest-burst-seconds .5)
(def delete-confirm-seconds .3)

;; What only the source's thread touches.
(defclass watch-thread ((device     : :t)          ; InotifyDevice, #f before the first try, 'none
                        (use-inotify? : :boolean)
                        (poll-every : :real)
                        (folders    : HashTable)   ; folder -> watch descriptor, or 'poll
                        (folder-of  : HashTable)   ; watch descriptor -> folder
                        (hashes     : HashTable)   ; path -> ((size modified identity) . hash)
                        (next-poll  : :real))
  final: #t)

;; The source's read procedure: (input previous) -> reading, where a
;; reading lists (path . summary) for every watched path, a summary being
;; (size device inode hash), 'other for what is not a regular file, or #f
;; for nothing. It returns only a reading different from PREVIOUS, or
;; PREVIOUS once the source is cancelled.
(def (watching-reader (w : watcher) (use-inotify? : :boolean) (poll-every : :real)) => :procedure
  (let (s (watch-thread device: #f use-inotify?: use-inotify? poll-every: poll-every
                        folders: (make-hash-table) folder-of: (make-hash-table) hashes: (make-hash-table)
                        next-poll: 0))
    (lambda (input previous)
      (read-changes! w s previous))))

(def (now-seconds) => :real
  (time->seconds (current-time)))

(def (read-changes! (w : watcher) (s : watch-thread) (previous :? :list)) => :list
  (let lp ((previous previous))
    (if (background-cancelled?)
      (begin
        (close-device! s)
        (or previous []))
      (let* ((taken (do-with-lock w.lock
                      (let (recheck? w.recheck?)
                        (set! w.recheck? #f)
                        (cons w.paths recheck?))))
             (paths (car taken))
             (recheck? (cdr taken)))
        (sync-folders! s paths)
        ;; Polled files are hashed again only when their stat changed;
        ;; the others whenever an event names them, since a file written
        ;; twice within the clock's tick keeps its size and time.
        (let* ((polled (polled-paths-due s paths))
               (dirty (if (or recheck? (not previous))
                        paths
                        (filter (lambda ((p : :string)) (not (assoc p previous))) paths)))
               (dirty (if (and (null? dirty) (null? polled)) (wait-for-events! s paths) dirty))
               (reading (map (lambda ((path : :string))
                               (let (old (and previous (assoc path previous)))
                                 (cond
                                  ((or (not old) (member path dirty)) (cons path (path-summary w s path #t)))
                                  ((member path polled) (cons path (path-summary w s path #f)))
                                  (else old))))
                             paths))
               (reading (confirm-missing! w s reading previous)))
          (if (equal? reading previous)
            (lp previous)
            reading))))))

;; READING with each path that went missing since PREVIOUS looked at again
;; after a moment.
(def (confirm-missing! (w : watcher) (s : watch-thread) (reading : :list) (previous :? :list)) => :list
  (let (gone? (lambda ((entry : :pair))
                (and (not (cdr entry))
                     previous
                     (let (old (assoc (car entry) previous))
                       (and old (cdr old) #t)))))
    (if (not (ormap gone? reading))
      reading
      (begin
        (thread-sleep! delete-confirm-seconds)
        (map (lambda ((entry : :pair))
               (if (gone? entry) (cons (car entry) (path-summary w s (car entry) #t)) entry))
             reading)))))

;; PATH's summary; its bytes are hashed again when FRESH? or its stat
;; changed.
(def (path-summary (w : watcher) (s : watch-thread) (path : :string) (fresh? : :boolean)) => :t
  (let (stat (with-catch (lambda (e) #f) (lambda () (w.stat path))))
    (cond
     ((not stat) (hash-remove! s.hashes path) #f)
     ((not (eq? (file-stat-kind stat) 'file)) 'other)
     (else
      (let* ((key [(file-stat-size stat) (file-stat-modified stat) (file-stat-identity stat)])
             (known (hash-get s.hashes path))
             (hash (if (and known (not fresh?) (equal? (car known) key))
                     (cdr known)
                     (let (hash (with-catch (lambda (e) #f)
                                  (lambda () (hex-encode (sha256 (w.read path))))))
                       (hash-put! s.hashes path (cons key hash))
                       hash))))
        [(file-stat-size stat) (car (file-stat-identity stat)) (cdr (file-stat-identity stat)) hash])))))

;;; Folders

;; STRINGS without repeats, in order.
(def (distinct (strings : :list)) => :list
  (let lp ((rest strings) (out []))
    (match rest
      ([] (reverse out))
      ([s . more] (lp more (if (member s out) out (cons s out)))))))

(def (folder-of-path (path : :string)) => :string
  (file-name-directory path))

;; The inotify device, made on first use; #f when there is none.
(def (inotify-device (s : watch-thread)) => :t
  (when (and (not s.device) s.use-inotify?)
    (set! s.device
      (with-catch (lambda (e) 'none)
        (lambda ()
          (let (device (inotify-init))
            ;; A source cancelled between two reads never closes it.
            (make-will device (lambda (d) (with-catch void (lambda () (device-close d)))))
            device)))))
  (and (InotifyDevice? s.device) s.device))

(def (close-device! (s : watch-thread)) => :void
  (when (InotifyDevice? s.device)
    (with-catch void (lambda () (device-close s.device))))
  (set! s.device 'none))

;; Watch exactly the folders of PATHS: inotify where it works, otherwise
;; polling.
(def (sync-folders! (s : watch-thread) (paths : :list)) => :void
  (let (needed (distinct (map folder-of-path paths)))
    (for-each (lambda ((folder : :string))
                (unless (member folder needed)
                  (let (wd (hash-get s.folders folder))
                    (when (fixnum? wd)
                      (hash-remove! s.folder-of wd)
                      (let (device (inotify-device s))
                        (when device
                          (with-catch void (lambda () (inotify-rm-watch device wd)))))))
                  (hash-remove! s.folders folder)))
              (hash-keys s.folders))
    (for-each (lambda ((folder : :string))
                (unless (hash-key? s.folders folder)
                  (let* ((device (inotify-device s))
                         (wd (and device
                                  (with-catch (lambda (e) #f)
                                    (lambda () (inotify-add-watch device folder watch-mask))))))
                    (hash-put! s.folders folder (or wd 'poll))
                    (when wd
                      (hash-put! s.folder-of wd folder)))))
              needed)))

(def (polled? (s : watch-thread)) => :boolean
  (and (find (lambda (wd) (eq? wd 'poll)) (hash-values s.folders)) #t))

;; The paths in polled folders, when a poll is due.
(def (polled-paths-due (s : watch-thread) (paths : :list)) => :list
  (if (and (polled? s) (>= (now-seconds) s.next-poll))
    (begin
      (set! s.next-poll (+ (now-seconds) s.poll-every))
      (filter (lambda ((path : :string)) (eq? (hash-get s.folders (folder-of-path path)) 'poll)) paths))
    []))

;; Wait up to idle-seconds (or the next poll) for events about PATHS, then
;; until they stop, and return the paths they were about.
(def (wait-for-events! (s : watch-thread) (paths : :list)) => :list
  (let* ((polled? (polled? s))
         (wait (if polled? (max 0 (min idle-seconds (- s.next-poll (now-seconds)))) idle-seconds))
         (device (inotify-device s))
         (first (if (and device (find fixnum? (hash-values s.folders)))
                  (inotify device wait)
                  (begin (thread-sleep! wait) #f))))
    (if (not first)
      []
      (let ((until (+ (now-seconds) longest-burst-seconds)))
        (let lp ((events first))
          (let (more (and (< (now-seconds) until) (inotify device quiet-seconds)))
            (if more
              (lp (append events more))
              (event-paths s events paths))))))))

;; The PATHS that EVENTS are about: every one after an overflow, every one
;; in a folder that went away.
(def (event-paths (s : watch-thread) (events : :list) (paths : :list)) => :list
  (let lp ((events events) (dirty []))
    (match events
      ([] (distinct dirty))
      ([event . more]
       (using (event : InotifyEvent)
         (let ((mask event.mask)
               (folder (hash-get s.folder-of event.wd)))
           (cond
            ((not (fxzero? (fxand mask IN_Q_OVERFLOW))) paths)
            ((not folder) (lp more dirty))
            ((string? event.name)
             (let (path (string-append folder event.name))
               (lp more (if (member path paths) (cons path dirty) dirty))))
            (else
             ;; The folder itself went or moved: watch it again, or poll.
             (when (not (fxzero? (fxand mask (fxior IN_IGNORED IN_DELETE_SELF IN_MOVE_SELF))))
               (hash-remove! s.folder-of event.wd)
               (hash-remove! s.folders folder))
             (lp more (append (filter (lambda ((p : :string)) (string=? (folder-of-path p) folder)) paths)
                              dirty))))))))))
