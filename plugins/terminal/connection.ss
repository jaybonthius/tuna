;;; Tuna's side of a terminal helper (ADR 18): starting a helper outside
;;; Tuna, detached as the process library does it
;;; (:tuna/lib/helper-processes), and the connection to it. No editor
;;; state here: the plugin owns what arrives.
;;;
;;; A connection sends frames through a device writer, in order, so the
;;; editor never waits on the socket; one other thread (the plugin's
;;; reader job) reads it, and closes it once it has ended.
prelude: :gerbil/core

(import :std/source
        :tuna/lib/unix
        :tuna/lib/helper-processes
        ./protocol)
(export default-helper-path
        default-terminfo-directory
        default-shell-integration-directory
        (struct-out helper-launch)
        launch-helper!
        connection
        connection?
        connection-device
        open-connection
        connection-send!
        close-connection!
        read-frames
        frame-inbox
        new-frame-inbox
        frame-inbox-put!
        frame-inbox-take!
        frame-inbox-close!)

;; This checkout's build: beside this source, two folders up, in .gerbil
;; (`make` builds both).
(def checkout-gerbil-directory
  (let (root (path-expand "../.." (path-expand (this-source-directory))))
    (path-expand ".gerbil" (with-catch (lambda (e) root) (lambda () (path-normalize root))))))

(def default-helper-path (path-expand "bin/tuna-terminal-helper" checkout-gerbil-directory))
(def default-terminfo-directory (path-expand "terminfo" checkout-gerbil-directory))
;; The shell integration scripts, beside this source.
(def default-shell-integration-directory (path-expand "shell" (path-expand (this-source-directory))))

;; What a helper is started with: the helper program, its socket, the
;; program's size, scrollback (bytes), folder and log file, the snapshot
;; file its terminal starts from ("" for none), the program and its
;; arguments, the environment, and whether to leave Tuna's scope as UNIT.
(defstruct helper-launch ((helper : :string)
                          (socket : :string)
                          (columns : :fixnum)
                          (rows : :fixnum)
                          (scrollback : :integer)
                          (directory : :string)
                          (log : :string)
                          (restore : :string)
                          (program : :list)
                          (environment : :list)
                          (unit :? :string))
  final: #t)

;; L's helper program and its arguments.
(def (helper-arguments (l : helper-launch)) => :list
  (append [(helper-launch-helper l)
           "--socket" (helper-launch-socket l)
           "--columns" (number->string (helper-launch-columns l))
           "--rows" (number->string (helper-launch-rows l))
           "--scrollback" (number->string (helper-launch-scrollback l))
           "--directory" (helper-launch-directory l)
           "--log" (helper-launch-log l)]
          (let (restore (helper-launch-restore l))
            (if (string-empty? restore) [] ["--restore" restore]))
          ["--"]
          (helper-launch-program l)))

;; Start L's helper and return once it is detached; raises when the
;; command to start it fails.
(def (launch-helper! (l : helper-launch)) => :void
  (launch-detached! (helper-arguments l) (helper-launch-environment l) (helper-launch-unit l)))

(defclass connection ((device : :t)
                      (writer : device-writer))
  final: #t)

;; A connection to the helper at socket PATH, which has said hello;
;; raises when there is none to connect to.
(def (open-connection (path : :string)) => connection
  (let* ((device (unix-connect path))
         (c (connection device: device writer: (new-device-writer device 'terminal-writer))))
    (connection-send! c 'hello (hello-payload))
    c))

;; Send a frame of TYPE with PAYLOAD, after those sent before.
(def (connection-send! (c : connection) (type : :symbol) (payload : :u8vector := (u8vector))) => :void
  (device-writer-send! c.writer (frame-bytes type payload)))

;; End C after the frames sent so far; its reader then sees the end.
(def (close-connection! (c : connection)) => :void
  (device-writer-close! c.writer))

;;; The inbox

;; Frames read from a helper that the editor has not yet taken: the
;; reader's thread puts them, the editor takes them all at once, so a
;; flood costs the editor one task per batch, not one per frame. While
;; more than LIMIT bytes wait, the reader waits too: it stops reading the
;; socket, the helper's queue fills, and the helper stops reading the
;; program, so a slow editor holds the program back instead of Tuna's
;; memory growing.
(defclass frame-inbox ((lock    : :mutex)
                 (taken   : :condvar)              ; the editor took the frames
                 (frames  : :list)                 ; newest first
                 (bytes   : :fixnum)               ; of their payloads
                 (limit   : :fixnum)
                 (closed? : :boolean))
  final: #t)

(def (new-frame-inbox (limit : :fixnum)) => frame-inbox
  (frame-inbox lock: (make-mutex 'terminal-inbox) taken: (make-condition-variable 'terminal-inbox)
         frames: [] bytes: 0 limit: limit closed?: #f))

;; On the reader's thread: add FRAMES, after waiting while more than the
;; limit waits; whether the inbox was empty, so the editor must be told.
;; Nothing is added once the inbox is closed.
(def (frame-inbox-put! (b : frame-inbox) (frames : :list)) => :boolean
  (let wait ()
    (mutex-lock! b.lock)
    (if (and (fx> b.bytes b.limit) (not b.closed?))
      (begin (mutex-unlock! b.lock b.taken) (wait))
      (let (empty? (null? b.frames))
        (unless b.closed?
          (for-each (lambda ((f : frame))
                      (set! b.frames (cons f b.frames))
                      (set! b.bytes (fx+ b.bytes (u8vector-length (frame-payload f)))))
                    frames))
        (mutex-unlock! b.lock)
        (and empty? (not b.closed?))))))

;; On the editor: every frame waiting, oldest first, the payloads of
;; output frames that follow each other joined into one; the reader may
;; go on.
(def (frame-inbox-take! (b : frame-inbox)) => :list
  (let (frames (do-with-lock b.lock
                 (let (frames b.frames)
                   (set! b.frames [])
                   (set! b.bytes 0)
                   (condition-variable-broadcast! b.taken)
                   frames)))
    (join-output frames)))

;; Close B: the reader no longer waits, and what it puts is dropped.
(def (frame-inbox-close! (b : frame-inbox)) => :void
  (do-with-lock b.lock
    (set! b.closed? #t)
    (set! b.frames [])
    (set! b.bytes 0)
    (condition-variable-broadcast! b.taken)))

;; NEWEST-FIRST, frames newest first, oldest first, with each run of
;; output frames one frame.
(def (join-output (newest-first : :list)) => :list
  (let lp ((frames newest-first) (run []) (out []))
    (match frames
      ([] (with-run run out))
      ([f . more]
       (if (eq? (frame-type f) 'output)
         (lp more (cons f run) out)
         (lp more [] (cons f (with-run run out))))))))

;; OUT with RUN, output frames oldest first, before it as one frame.
(def (with-run (run : :list) (out : :list)) => :list
  (cond
   ((null? run) out)
   ((null? (cdr run)) (cons (car run) out))
   (else (cons (make-frame 'output (joined-payloads run)) out))))

;; The payloads of FRAMES, one after another, in one vector.
(def (joined-payloads (frames : :list)) => :u8vector
  (let (out (make-u8vector (foldl (lambda ((f : frame) (n : :fixnum)) (fx+ n (u8vector-length (frame-payload f))))
                                  0 frames)
                           0))
    (foldl (lambda ((f : frame) (at : :fixnum))
             (let (payload (frame-payload f))
               (subu8vector-move! payload 0 (u8vector-length payload) out at)
               (fx+ at (u8vector-length payload))))
           0 frames)
    out))

;; On the reader's thread: the next frames from C's DEVICE, waiting for
;; them, with READER and BUFFER kept between calls; #f once the connection
;; has ended, after which DEVICE is closed.
(def (read-frames (device : :t) (reader : frame-reader) (buffer : :u8vector)) => (Maybe :list)
  (let lp ()
    (let (n (with-catch (lambda (e) 0) (lambda () (device-read-some device buffer))))
      (if (fx= n 0)
        (begin
          (with-catch void (lambda () (close-device device)))
          #f)
        (let (frames (with-catch (lambda (e) #f) (lambda () (frame-reader-feed! reader buffer 0 n))))
          (cond
           ((not frames)                ; not the protocol: end it
            (with-catch void (lambda () (close-device device)))
            #f)
           ((null? frames) (lp))
           (else frames)))))))
