;;; Tuna's side of a Pi helper (helper.ss): starting one detached, as the
;;; process library does it (:tuna/lib/helper-processes), the connection to
;;; it, and the inbox its reader puts records in. No editor state: the
;;; plugin owns what arrives.
;;;
;;; A connection writes lines through a device writer, in order, so the
;;; editor never waits on the socket; one other thread (the chat's reader
;;; job) reads it, parses each line, and closes it once it has ended.
prelude: :gerbil/core

(import :std/source
        :tuna/lib/unix
        :tuna/lib/helper-processes
        ./jsonl)
(export default-helper-path
        (struct-out helper-launch)
        launch-helper!
        connection
        connection?
        connection-device
        open-connection
        connection-send!
        close-connection!
        read-records
        record-inbox
        new-record-inbox
        record-inbox-put!
        record-inbox-take!
        record-inbox-close!)

;; This checkout's build: beside this source, two folders up, in .gerbil
;; (`make` builds it).
(def default-helper-path
  (let (root (path-expand "../.." (path-expand (this-source-directory))))
    (path-expand "bin/tuna-pi-helper"
                 (path-expand ".gerbil" (with-catch (lambda (e) root) (lambda () (path-normalize root)))))))

;; What a helper is started with: the helper program, its socket, Pi's
;; folder, the log file, the idle exit in seconds, Pi's model and thinking
;; level (#f for Pi's own), the trust ("approve", "default" or
;; "no-approve"), the session file to open (#f for a new chat), the
;; command that runs Pi, and whether to leave Tuna's scope as UNIT.
(defstruct helper-launch ((helper : :string)
                          (socket : :string)
                          (directory : :string)
                          (log : :string)
                          (idle-exit : :real)
                          (model :? :string)
                          (thinking :? :string)
                          (trust : :string)
                          (session :? :string)
                          (command : :list)
                          (unit :? :string))
  final: #t)

(def (helper-arguments (l : helper-launch)) => :list
  (append [(helper-launch-helper l)
           "--socket" (helper-launch-socket l)
           "--directory" (helper-launch-directory l)
           "--log" (helper-launch-log l)
           "--idle-exit" (number->string (helper-launch-idle-exit l))
           "--trust" (helper-launch-trust l)]
          (let (m (helper-launch-model l)) (if m ["--model" m] []))
          (let (t (helper-launch-thinking l)) (if t ["--thinking" t] []))
          (let (s (helper-launch-session l)) (if s ["--session" s] []))
          ["--"]
          (helper-launch-command l)))

;; Start L's helper and return once it is detached; raises when the
;; command to start it fails.
(def (launch-helper! (l : helper-launch)) => :void
  (launch-detached! (helper-arguments l) #f (helper-launch-unit l)))

(defclass connection ((device : :t)
                      (writer : device-writer))
  final: #t)

;; A connection to the helper at socket PATH; raises when there is none
;; to connect to.
(def (open-connection (path : :string)) => connection
  (let (device (unix-connect path))
    (connection device: device writer: (new-device-writer device 'pi-writer))))

;; Send RECORD (a hash table) as a line, after those sent before.
(def (connection-send! (c : connection) (record : :t)) => :void
  (device-writer-send! c.writer (json-line-bytes record)))

;; End C after the lines sent so far; its reader then sees the end.
(def (close-connection! (c : connection)) => :void
  (device-writer-close! c.writer))

;;; The inbox

;; Records read from a helper that the editor has not yet taken: the
;; reader's thread puts them, the editor takes them all at once, so a
;; stream of deltas costs the editor one task per batch. While more than
;; LIMIT bytes of lines wait, the reader waits too.
(defclass record-inbox ((lock    : :mutex)
                        (taken   : :condvar)
                        (records : :list)         ; newest first
                        (bytes   : :fixnum)
                        (limit   : :fixnum)
                        (closed? : :boolean))
  final: #t)

(def (new-record-inbox (limit : :fixnum)) => record-inbox
  (record-inbox lock: (make-mutex 'pi-inbox) taken: (make-condition-variable 'pi-inbox)
                records: [] bytes: 0 limit: limit closed?: #f))

;; On the reader's thread: add RECORDS, oldest first, BYTES long in all,
;; after waiting while more than the limit waits; whether the inbox was
;; empty, so the editor must be told. Nothing is added once it is closed.
(def (record-inbox-put! (b : record-inbox) (records : :list) (bytes : :fixnum)) => :boolean
  (let wait ()
    (mutex-lock! b.lock)
    (if (and (fx> b.bytes b.limit) (not b.closed?))
      (begin (mutex-unlock! b.lock b.taken) (wait))
      (let (empty? (null? b.records))
        (unless b.closed?
          (for-each (lambda (r) (set! b.records (cons r b.records))) records)
          (set! b.bytes (fx+ b.bytes bytes)))
        (mutex-unlock! b.lock)
        (and empty? (not b.closed?))))))

;; On the editor: every record waiting, oldest first; the reader may go on.
(def (record-inbox-take! (b : record-inbox)) => :list
  (do-with-lock b.lock
    (let (records b.records)
      (set! b.records [])
      (set! b.bytes 0)
      (condition-variable-broadcast! b.taken)
      (reverse records))))

;; Close B: the reader no longer waits, and what it puts is dropped.
(def (record-inbox-close! (b : record-inbox)) => :void
  (do-with-lock b.lock
    (set! b.closed? #t)
    (set! b.records [])
    (set! b.bytes 0)
    (condition-variable-broadcast! b.taken)))

;; On the reader's thread: the next records from DEVICE, each a JSON
;; object, and how many bytes their lines had, as a pair, waiting for at
;; least one; READER and BUFFER are kept between calls. #f once the
;; connection has ended, after which DEVICE is closed. Lines that are not
;; JSON objects are skipped.
(def (read-records (device : :t) (reader : jsonl-reader) (buffer : :u8vector)) => (Maybe :pair)
  (let lp ()
    (let (n (with-catch (lambda (e) 0) (lambda () (device-read-some device buffer))))
      (if (fx= n 0)
        (begin
          (with-catch void (lambda () (close-device device)))
          #f)
        (let (records (filter-map parse-json-line (jsonl-reader-feed! reader buffer 0 n)))
          (if (null? records)
            (lp)
            (cons records n)))))))
