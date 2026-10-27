;;; What a terminal helper and the terminal plugin say to each other over
;;; the helper's socket (ADR 18). Every message is a frame: one byte saying
;;; what it is, the length of its payload as four bytes (most significant
;;; first), then the payload. Numbers in payloads are unsigned and most
;;; significant byte first.
;;;
;;; Tuna speaks first, with `hello` and the protocol version it speaks. The
;;; helper answers `hello` with its version, its own pid, its program's pid
;;; and its size, then `snapshot` (its terminal as libghostty snapshot
;;; bytes), then every byte the program writes as `output`, and `exit` with
;;; the program's status once it ended; or `refused` with a reason, and
;;; closes. Tuna sends `input` (bytes for the program), `resize`, `focus`,
;;; `snapshot-request` (answered by `snapshot`, after which output resumes),
;;; `kill`, and `exit-ack` once it has shown the exit.
prelude: :gerbil/core

(export protocol-version
        frame-bytes
        frame-type-name
        (struct-out frame frame-reader)
        new-frame-reader
        frame-reader-feed!
        u16-bytes u32-bytes bytes-u16 bytes-u32
        hello-payload parse-hello
        helper-hello-payload (struct-out helper-hello) parse-helper-hello
        resize-payload (struct-out resize-request) parse-resize
        exit-payload parse-exit)

;; A helper and a plugin with different versions do not talk.
(def protocol-version 1)

;; The largest payload either side accepts: a snapshot of a terminal with a
;; very large scrollback fits.
(def maximum-payload (* 256 1024 1024))

(def frame-types
  '((hello . 1) (refused . 2) (snapshot . 3) (output . 4) (exit . 5)
    (input . 65) (resize . 66) (focus . 67) (snapshot-request . 68) (kill . 69) (exit-ack . 70)))

;; One message: TYPE, a symbol of frame-types, and its PAYLOAD.
(defstruct frame ((type : :symbol) (payload : :u8vector))
  final: #t)

(def (frame-type-code (type : :symbol)) => :fixnum
  (let (pair (assq type frame-types))
    (unless pair (error "Not a terminal frame type" type))
    (cdr pair)))

;; The name of frame type CODE, or #f.
(def (frame-type-name (code : :fixnum)) => (Maybe :symbol)
  (let (pair (find (lambda ((pair : :pair)) (fx= (cdr pair) code)) frame-types))
    (and pair (car pair))))

(def (u16-bytes (n : :fixnum)) => :u8vector
  (u8vector (fxand (fxarithmetic-shift-right n 8) 255) (fxand n 255)))

(def (u32-bytes (n : :integer)) => :u8vector
  (u8vector (bitwise-and (arithmetic-shift n -24) 255) (bitwise-and (arithmetic-shift n -16) 255)
            (bitwise-and (arithmetic-shift n -8) 255) (bitwise-and n 255)))

(def (bytes-u16 (bytes : :u8vector) (at : :fixnum)) => :fixnum
  (fx+ (fx* 256 (u8vector-ref bytes at)) (u8vector-ref bytes (fx1+ at))))

(def (bytes-u32 (bytes : :u8vector) (at : :fixnum)) => :integer
  (+ (* 16777216 (u8vector-ref bytes at)) (* 65536 (u8vector-ref bytes (fx+ at 1)))
     (* 256 (u8vector-ref bytes (fx+ at 2))) (u8vector-ref bytes (fx+ at 3))))

;; The frame of TYPE with PAYLOAD, as bytes to send.
(def (frame-bytes (type : :symbol) (payload : :u8vector := (u8vector))) => :u8vector
  (u8vector-append (u8vector (frame-type-code type)) (u32-bytes (u8vector-length payload)) payload))

;; What has arrived of the frame being read: its header, then its payload.
(defclass frame-reader ((header  : :u8vector)    ; five bytes
                        (filled  : :fixnum)      ; of the header, then of the payload
                        (type    :? :symbol)     ; once the header is complete
                        (payload :? :u8vector))
  final: #t)

(def (new-frame-reader) => frame-reader
  (frame-reader header: (make-u8vector 5 0) filled: 0 type: #f payload: #f))

;; The frames completed by BYTES from START to END, in order; raises on a
;; frame no version of the protocol sends.
(def (frame-reader-feed! (r : frame-reader) (bytes : :u8vector)
                         (start : :fixnum := 0) (end : :fixnum := (u8vector-length bytes)))
  => :list
  (let lp ((at start) (out []))
    (cond
     ((fx= at end) (reverse out))
     ((not r.payload)
      (let (take (fxmin (fx- 5 r.filled) (fx- end at)))
        (subu8vector-move! bytes at (fx+ at take) r.header r.filled)
        (set! r.filled (fx+ r.filled take))
        (when (fx= r.filled 5)
          (let ((type (frame-type-name (u8vector-ref r.header 0)))
                (length (bytes-u32 r.header 1)))
            (unless type (error "Unknown terminal frame type" (u8vector-ref r.header 0)))
            (when (> length maximum-payload) (error "Terminal frame too large" length))
            (set! r.type type)
            (set! r.payload (make-u8vector length 0))
            (set! r.filled 0)))
        (lp (fx+ at take) (complete-frame r out))))
     (else
      (let* ((payload r.payload)
             (take (fxmin (fx- (u8vector-length payload) r.filled) (fx- end at))))
        (subu8vector-move! bytes at (fx+ at take) payload r.filled)
        (set! r.filled (fx+ r.filled take))
        (lp (fx+ at take) (complete-frame r out)))))))

;; OUT with R's frame added when its payload is complete, which starts the
;; next frame.
(def (complete-frame (r : frame-reader) (out : :list)) => :list
  (let (payload r.payload)
    (if (and payload (fx= r.filled (u8vector-length payload)))
      (let (done (make-frame r.type payload))
        (set! r.type #f)
        (set! r.payload #f)
        (set! r.filled 0)
        (cons done out))
      out)))

;;; Payloads

(def (hello-payload) => :u8vector
  (u16-bytes protocol-version))

;; The protocol version a hello from Tuna names.
(def (parse-hello (payload : :u8vector)) => :fixnum
  (if (fx>= (u8vector-length payload) 2) (bytes-u16 payload 0) 0))

;; A helper's hello: its protocol VERSION, its own pid, its program's pid,
;; and its terminal's size.
(defstruct helper-hello ((version : :fixnum)
                         (helper-pid : :fixnum)
                         (child-pid : :fixnum)
                         (columns : :fixnum)
                         (rows : :fixnum))
  final: #t)

(def (helper-hello-payload (h : helper-hello)) => :u8vector
  (u8vector-append (u16-bytes (helper-hello-version h))
                   (u32-bytes (helper-hello-helper-pid h)) (u32-bytes (helper-hello-child-pid h))
                   (u16-bytes (helper-hello-columns h)) (u16-bytes (helper-hello-rows h))))

;; A helper's hello; a payload too short to be one (an older helper's)
;; gives only its version.
(def (parse-helper-hello (payload : :u8vector)) => helper-hello
  (if (fx>= (u8vector-length payload) 14)
    (make-helper-hello (bytes-u16 payload 0) (bytes-u32 payload 2) (bytes-u32 payload 6)
                       (bytes-u16 payload 10) (bytes-u16 payload 12))
    (make-helper-hello (if (fx>= (u8vector-length payload) 2) (bytes-u16 payload 0) 0) 0 0 0 0)))

;; A new size: COLUMNS x ROWS cells, each CELL-WIDTH x CELL-HEIGHT px.
(defstruct resize-request ((columns : :fixnum)
                           (rows : :fixnum)
                           (cell-width : :fixnum)
                           (cell-height : :fixnum))
  final: #t)

(def (resize-payload (r : resize-request)) => :u8vector
  (u8vector-append (u16-bytes (resize-request-columns r)) (u16-bytes (resize-request-rows r))
                   (u16-bytes (resize-request-cell-width r)) (u16-bytes (resize-request-cell-height r))))

(def (parse-resize (payload : :u8vector)) => (Maybe resize-request)
  (and (fx>= (u8vector-length payload) 8)
       (let ((columns (bytes-u16 payload 0))
             (rows (bytes-u16 payload 2)))
         (and (fx> columns 0) (fx> rows 0)
              (make-resize-request columns rows (bytes-u16 payload 4) (bytes-u16 payload 6))))))

;; A program's exit STATUS: its exit code, or 128 plus the signal that
;; ended it.
(def (exit-payload (status : :fixnum)) => :u8vector
  (u16-bytes status))

(def (parse-exit (payload : :u8vector)) => :fixnum
  (if (fx>= (u8vector-length payload) 2) (bytes-u16 payload 0) 255))
