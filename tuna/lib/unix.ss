;;; The Unix system calls helper processes and Tuna share (ADR 18's
;;; process library): private folders, Unix sockets that check the user
;;; id of the process at the other end, raw device reads and writes, a
;;; session of one's own and standard ports dropped. A library (ADR 12):
;;; no editor state.
;;;
;;; Every descriptor is non-blocking and close-on-exec, and is read and
;;; written through a Gambit raw device (:std/os/device), so a thread
;;; waiting for it waits in Gambit's scheduler, never in the operating
;;; system, and the other threads run on. Failures raise, with the
;;; system's description of the error.
prelude: :gerbil/core

(import :std/ffi
        (only-in :std/os/device __open-raw-device DIRECTION-INOUT device-close device-wait-input!
                 device-wait-output! OSDevice OSDevice-fd)
        (only-in :std/os/file FileDevice)
        (only-in :std/time/timeout IOTimeout))
(export current-user-id
        current-process-id
        start-session
        redirect-standard-ports
        make-private-directory
        unix-listen
        unix-accept
        unix-connect
        fd-device
        device-fd
        device-read-some
        device-write-all
        close-device
        shutdown-device
        errno-name)

(C-ffi-macrology)
(C-include "<errno.h>" "<fcntl.h>" "<string.h>" "<unistd.h>" "<sys/socket.h>" "<sys/stat.h>"
           "<sys/types.h>" "<sys/un.h>")

(C-declare #<<END-C
/* Declared here rather than through _GNU_SOURCE, which the static build of
   a helper program does not pass to the compiler. */
extern int accept4(int, struct sockaddr *, socklen_t *, int);
struct tuna_unix_ucred { pid_t pid; uid_t uid; gid_t gid; };

static int tuna_unix_listen(const char *path) {
  struct sockaddr_un address = {.sun_family = AF_UNIX};
  if (strlen(path) >= sizeof address.sun_path) return -ENAMETOOLONG;
  strcpy(address.sun_path, path);
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
  if (fd < 0) return -errno;
  unlink(path);
  mode_t old = umask(0177);
  int r = bind(fd, (struct sockaddr *)&address, sizeof address);
  umask(old);
  if (r < 0 || chmod(path, 0600) < 0 || listen(fd, 4) < 0) { int e = errno; close(fd); return -e; }
  return fd;
}

/* -EPERM when the process at the other end of FD runs as another user. */
static int tuna_unix_check_peer(int fd) {
  struct tuna_unix_ucred credentials;
  socklen_t length = sizeof credentials;
  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) < 0) return -errno;
  return credentials.uid == getuid() ? 0 : -EPERM;
}

static int tuna_unix_accept(int listener) {
  int fd = accept4(listener, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
  if (fd < 0) return -errno;
  int r = tuna_unix_check_peer(fd);
  if (r < 0) { close(fd); return r; }
  return fd;
}

static int tuna_unix_connect(const char *path) {
  struct sockaddr_un address = {.sun_family = AF_UNIX};
  if (strlen(path) >= sizeof address.sun_path) return -ENAMETOOLONG;
  strcpy(address.sun_path, path);
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return -errno;
  if (connect(fd, (struct sockaddr *)&address, sizeof address) < 0) { int e = errno; close(fd); return -e; }
  int r = tuna_unix_check_peer(fd);
  if (r < 0 || fcntl(fd, F_SETFL, O_NONBLOCK) < 0) { int e = r < 0 ? -r : errno; close(fd); return -e; }
  return fd;
}

/* Make folder PATH if it does not exist; then it must be a folder, not a
   link, owned by this user and closed to others (mode 0700). */
static int tuna_unix_private_directory(const char *path) {
  if (mkdir(path, 0700) < 0 && errno != EEXIST) return -errno;
  struct stat s;
  if (lstat(path, &s) < 0) return -errno;
  if (!S_ISDIR(s.st_mode) || s.st_uid != getuid()) return -EPERM;
  if ((s.st_mode & 0077) && chmod(path, 0700) < 0) return -errno;
  return 0;
}

static int tuna_unix_redirect(const char *log) {
  int null = open("/dev/null", O_RDWR);
  if (null < 0) return -errno;
  int err = log[0] ? open(log, O_WRONLY | O_CREAT | O_APPEND, 0600) : null;
  if (err < 0) err = null;
  dup2(null, 0); dup2(null, 1); dup2(err, 2);
  if (err > 2) close(err);
  if (null > 2 && null != err) close(null);
  return 0;
}
END-C
)

(def-C-lambda current-user-id () int "___return(getuid());")
(def-C-lambda current-process-id () int "___return(getpid());")
(def-C-lambda %setsid () int "___return(setsid() < 0 ? -errno : 0);")
(def-C-lambda %redirect (UTF-8-string) int "tuna_unix_redirect")
(def-C-lambda %private-directory (UTF-8-string) int "tuna_unix_private_directory")
(def-C-lambda %listen (UTF-8-string) int "tuna_unix_listen")
(def-C-lambda %accept (int) int "tuna_unix_accept")
(def-C-lambda %connect (UTF-8-string) int "tuna_unix_connect")
(def-C-lambda %read (int scheme-object int int) int
  "ssize_t n;
   do { n = read(___arg1, (char *)___BODY_AS(___arg2, ___tSUBTYPED) + ___arg3, ___arg4); }
   while (n < 0 && errno == EINTR);
   ___return(n < 0 ? -errno : (int)n);")
(def-C-lambda %write (int scheme-object int int) int
  "ssize_t n;
   do { n = write(___arg1, (char *)___BODY_AS(___arg2, ___tSUBTYPED) + ___arg3, ___arg4); }
   while (n < 0 && errno == EINTR);
   ___return(n < 0 ? -errno : (int)n);")
(def-C-lambda %shutdown (int) int "___return(shutdown(___arg1, SHUT_RDWR) < 0 ? -errno : 0);")
(def-C-lambda %errno-name (int) char-string "___return(strerror(___arg1));")
(def-C-lambda %eagain () int "___return(EAGAIN);")
(def-C-lambda %eio () int "___return(EIO);")

(def eagain (%eagain))
(def eio (%eio))

;; The system's description of error number ERRNO.
(def (errno-name (errno : :fixnum)) => :string
  (%errno-name errno))

(def (check (what : :string) (result : :fixnum)) => :fixnum
  (if (fx< result 0)
    (error (string-append what ": " (errno-name (fx- 0 result))))
    result))

;; Make this process the leader of a new session, unless it already is.
(def (start-session) => :void
  (%setsid)
  (void))

;; Standard input and output to /dev/null; standard error to LOG ("" for
;; /dev/null too).
(def (redirect-standard-ports (log : :string)) => :void
  (check "Cannot redirect the standard ports" (%redirect log))
  (void))

;; Make folder PATH, whose parent exists, private to this user.
(def (make-private-directory (path : :string)) => :void
  (check (string-append "Cannot use " path " as a private folder") (%private-directory path))
  (void))

;;; Sockets and devices

;; A descriptor as a raw device, which a thread waits on in Gambit's
;; scheduler. The device owns FD from now on.
(def (fd-device (fd : :fixnum) (name : :string)) => FileDevice
  (FileDevice (__open-raw-device 'unix fd DIRECTION-INOUT) fd DIRECTION-INOUT name))

;; DEVICE's descriptor.
(def (device-fd (device : FileDevice)) => :fixnum
  (OSDevice-fd device))

;; A Unix socket listening at PATH (replacing what is there), readable and
;; writable only by this user.
(def (unix-listen (path : :string)) => FileDevice
  (fd-device (check (string-append "Cannot listen at " path) (%listen path)) path))

;; The next connection to LISTENER from a process of this user, waiting
;; for one; connections from other users are refused and closed.
(def (unix-accept (listener : FileDevice)) => FileDevice
  (let lp ()
    (let (fd (%accept (OSDevice-fd listener)))
      (cond
       ((fx>= fd 0) (fd-device fd "connection"))
       ((fx= fd (fx- 0 eagain)) (device-wait-input! listener (IOTimeout #f)) (lp))
       ((fx= fd -1) (lp))               ; EPERM: another user
       (else (check "Cannot accept a connection" fd))))))

;; A connection to the socket at PATH, whose listener must run as this
;; user; raises when it cannot connect.
(def (unix-connect (path : :string)) => FileDevice
  (fd-device (check (string-append "Cannot connect to " path) (%connect path)) path))

;; Read what is there, up to the size of BUFFER, waiting until something
;; is: the number of bytes, or 0 at the end, which includes a
;; pseudo-terminal's master once its program and every process holding
;; the terminal have closed it (EIO).
(def (device-read-some (device : FileDevice) (buffer : :u8vector)) => :fixnum
  (let lp ()
    (let (n (%read (OSDevice-fd device) buffer 0 (u8vector-length buffer)))
      (cond
       ((fx>= n 0) n)
       ((fx= n (fx- 0 eagain)) (device-wait-input! device (IOTimeout #f)) (lp))
       ((fx= n (fx- 0 eio)) 0)
       (else (check "Cannot read" n))))))

;; Write BYTES from START to END, waiting while the other end is full.
(def (device-write-all (device : FileDevice) (bytes : :u8vector)
                       (start : :fixnum := 0) (end : :fixnum := (u8vector-length bytes)))
  => :void
  (let lp ((start start))
    (when (fx< start end)
      (let (n (%write (OSDevice-fd device) bytes start (fx- end start)))
        (cond
         ((fx> n 0) (lp (fx+ start n)))
         ((or (fx= n 0) (fx= n (fx- 0 eagain))) (device-wait-output! device (IOTimeout #f)) (lp start))
         (else (check "Cannot write" n)))))))

;; End both directions of socket DEVICE without closing it: a thread
;; reading it sees its end, and closes it, so no thread waits on a closed
;; descriptor.
(def (shutdown-device (device : FileDevice)) => :void
  (%shutdown (OSDevice-fd device))
  (void))

;; Close DEVICE, once.
(def (close-device (device : FileDevice)) => :void
  (device-close device))
