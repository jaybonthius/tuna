;;; The reverse-proxy boundary of the web transport (ADR 10): a request
;;; from a peer that is not this machine's loopback must carry the proxy
;;; secret, which only the reverse proxy knows.
prelude: :gerbil/core

(import :std/misc/ports
        :std/net/address)
(export loopback-peer? secret-matches? read-proxy-secret)

;; Whether ADDRESS, a request's peer, is this machine's loopback.
(def (loopback-peer? (address : :t)) => :boolean
  (and (InetAddress? address)
       (let* ((ip (InetAddress-net address))
              (bytes (IPAddress-bytes ip)))
         (cond
          ((IP4Address? ip) (fx= (u8vector-ref bytes 0) 127))
          ((IP6Address? ip) (equal? bytes #u8(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1)))
          (else #f)))))

;; Whether GIVEN, a request's proxy-secret header, is SECRET, compared in
;; time independent of where they differ. No secret configured matches
;; nothing.
(def (secret-matches? (secret :? :u8vector) (given :? :string)) => :boolean
  (and secret given
       (let (bytes (string->utf8 given))
         (and (fx= (u8vector-length bytes) (u8vector-length secret))
              (let loop ((i 0) (difference 0))
                (if (fx< i (u8vector-length secret))
                  (loop (fx1+ i) (fxior difference (fxxor (u8vector-ref bytes i) (u8vector-ref secret i))))
                  (fx= difference 0)))))))

;; The proxy secret in PATH, without surrounding whitespace; PATH must be
;; readable by its owner only.
(def (read-proxy-secret (path : :string)) => :u8vector
  (let (mode (fxand (file-info-mode (file-info path)) #o077))
    (unless (fx= mode 0)
      (error "The proxy secret file must not be readable by group or others (chmod 600)" path)))
  (let* ((raw (read-file-string path))
         (end (string-length raw))
         (start (let lp ((i 0)) (if (and (fx< i end) (char-whitespace? (string-ref raw i))) (lp (fx1+ i)) i)))
         (stop (let lp ((i end)) (if (and (fx> i start) (char-whitespace? (string-ref raw (fx1- i)))) (lp (fx1- i)) i)))
         (text (substring raw start stop)))
    (when (fx< (string-length text) 16)
      (error "The proxy secret must be at least 16 characters" path))
    (string->utf8 text)))

