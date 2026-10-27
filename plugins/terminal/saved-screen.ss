;;; Saved screens (ADR 18): a terminal's screen and some of its
;;; scrollback, as libghostty snapshot bytes in a file only its owner can
;;; read, which its helper writes now and then so the terminal can come
;;; back after a reboot. The helper writes them; the terminal plugin reads
;;; them, shows one under a note that it was restored, and removes those of
;;; terminals killed on purpose.
prelude: :gerbil/core

(import (rename-in :gerbil-libghostty/ghostty (terminal? ghostty-terminal?)))
(export write-saved-screen!
        read-saved-screen
        delete-saved-screen!
        trimmed-snapshot
        restored-terminal)

;; Replace the file at PATH with BYTES, owner-only (0600): written beside
;; it, then renamed over it, so a reader sees the old file or the new.
(def (write-saved-screen! (path : :string) (bytes : :u8vector)) => :void
  (let (temporary (string-append path ".tmp"))
    (with-catch void (lambda () (delete-file temporary)))
    (let (port (open-output-file [path: temporary permissions: #o600 create: #t truncate: #t]))
      (unwind-protect
        (begin
          (write-subu8vector bytes 0 (u8vector-length bytes) port)
          ;; Gambit syncs a file port's data to the disk on this.
          (force-output port 1))
        (close-port port)))
    (rename-file temporary path #t)))

;; The bytes of the file at PATH, or #f when it cannot be read.
(def (read-saved-screen (path : :string)) => (Maybe :u8vector)
  (with-catch
   (lambda (e) #f)
   (lambda ()
     (and (file-exists? path)
          (let* ((size (file-info-size (file-info path)))
                 (bytes (make-u8vector size 0)))
            (call-with-input-file [path: path]
              (lambda (port)
                (and (fx= (read-subu8vector bytes 0 size port) size) bytes))))))))

(def (delete-saved-screen! (path : :string)) => :void
  (with-catch void (lambda () (delete-file path))))

;; SNAPSHOT, a terminal's snapshot bytes, with at most ROWS rows of
;; scrollback (#f for all): libghostty trims whole pages, so a little more
;; may be kept.
(def (trimmed-snapshot (snapshot : :u8vector) (rows :? :integer)) => :u8vector
  (if (not rows)
    snapshot
    (let (copy (snapshot-bytes->terminal snapshot))
      (try
       (if (<= (terminal-scrollback-rows copy) rows)
         snapshot
         (begin
           (terminal-set-scrollback-max-lines! copy rows)
           (terminal->snapshot-bytes copy)))
       (finally (terminal-close! copy))))))

;; What ends whatever the programs that wrote a saved screen left on, before
;; the note: a soft reset (cursor, modes, colours, scroll region),
;; synchronized output, mouse reports, focus reports, bracketed paste and
;; the Kitty keyboard flags.
(def restore-reset
  (string->utf8 (string-append "\x1b;[!p\x1b;[?2026l\x1b;[?1000l\x1b;[?1002l\x1b;[?1003l"
                               "\x1b;[?1006l\x1b;[?1004l\x1b;[?2004l\x1b;[=0;1u")))

;; Leaves the alternate screen, whose program is gone, as when it ends;
;; only there, since on the primary screen it would move the cursor.
(def leave-alternate-screen (string->utf8 "\x1b;[?1049l"))

;; A terminal of COLUMNS x ROWS showing the saved screen BYTES (a
;; snapshot; #f, or one this libghostty cannot read, for an empty screen)
;; with the programs' modes ended and NOTE on a line of its own after it,
;; in reverse video.
(def (restored-terminal (bytes :? :u8vector) (columns : :fixnum) (rows : :fixnum) (note : :string)) => terminal
  (let (term (or (and bytes (with-catch (lambda (e) #f) (lambda () (snapshot-bytes->terminal bytes))))
                 (make-terminal columns rows)))
    (terminal-resize! term columns rows)
    (when (eq? (terminal-active-screen term) 'alternate)
      (terminal-write! term leave-alternate-screen))
    (terminal-write! term restore-reset)
    ;; On a line of its own: a new one unless the cursor starts an empty one.
    (terminal-write! term (string->utf8 (string-append (if (fx> (cursor-state-x (terminal-cursor term)) 0) "\r\n" "")
                                                       "\x1b;[7m " note " \x1b;[0m\r\n")))
    term))
