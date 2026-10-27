;;; The system calls a terminal needs, for the helper program and the
;;; terminal plugin (ADR 18): starting a program on a pseudo-terminal,
;;; resizing it, waiting for and signalling it, and private Unix sockets
;;; that check the user id of the process at the other end.
;;;
;;; Every descriptor is non-blocking and close-on-exec, and is read and
;;; written through a Gambit raw device (:std/os/device), so a thread
;;; waiting for it waits in Gambit's scheduler, never in the operating
;;; system, and the other threads run on. Failures return -errno.
;;;
;;; Gambit is not used to start the program because its pseudo-terminal
;;; option is unreliable and its process ports do not make the program a
;;; session leader with the terminal as its controlling terminal; the C
;;; here forks and calls only async-signal-safe functions in the child.
prelude: :gerbil/core

(import :std/ffi
        (only-in :std/os/device __open-raw-device DIRECTION-INOUT device-close device-wait-input!
                 device-wait-output! OSDevice OSDevice-fd)
        (only-in :std/os/file FileDevice)
        (only-in :std/time/timeout IOTimeout))
(export spawn-on-pty
        pty-resize
        pty-foreground-group
        child-status
        signal-group
        current-user-id
        current-process-id
        start-session
        default-child-signal
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
        errno-name
        local-time-text)

(C-ffi-macrology)
(C-include "<errno.h>" "<fcntl.h>" "<signal.h>" "<stdint.h>" "<stdlib.h>" "<string.h>"
           "<termios.h>" "<unistd.h>" "<sys/ioctl.h>" "<sys/socket.h>" "<sys/stat.h>"
           "<sys/types.h>" "<sys/un.h>" "<sys/wait.h>" "<time.h>")

(C-declare #<<END-C
/* Declared here rather than through _GNU_SOURCE, which the static build of
   the helper program does not pass to the compiler. */
extern int posix_openpt(int);
extern int grantpt(int);
extern int unlockpt(int);
extern int ptsname_r(int, char *, size_t);
extern int accept4(int, struct sockaddr *, socklen_t *, int);
struct tuna_terminal_ucred { pid_t pid; uid_t uid; gid_t gid; };

/* NUL-terminated strings packed one after another in BLOB, COUNT of them,
   as a NULL-terminated vector. */
static char **tuna_terminal_strings(char *blob, int count, char **rest) {
  char **out = calloc((size_t)count + 1, sizeof(char *));
  if (!out) return NULL;
  for (int i = 0; i < count; ++i) { out[i] = blob; blob += strlen(blob) + 1; }
  out[count] = NULL;
  *rest = blob;
  return out;
}

/* Start PATH with ARGC arguments then ENVC environment entries from BLOB,
   in CWD (when not empty), on a new pseudo-terminal of COLUMNS x ROWS as
   its controlling terminal, in a session of its own. OUT receives the
   master descriptor and the pid. */
static int tuna_terminal_spawn(const char *path, char *blob, int argc, int envc,
                               const char *cwd, int columns, int rows, int32_t *out) {
  char *rest = blob, *more;
  char **argv = tuna_terminal_strings(rest, argc, &more);
  char **envp = argv ? tuna_terminal_strings(more, envc, &more) : NULL;
  int master = -1, slave = -1, error = 0;
  char name[128];
  if (!argv || !envp) { error = ENOMEM; goto done; }
  master = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC);
  if (master < 0 || grantpt(master) < 0 || unlockpt(master) < 0 ||
      ptsname_r(master, name, sizeof name) != 0) { error = errno; goto done; }
  slave = open(name, O_RDWR | O_NOCTTY | O_CLOEXEC);
  if (slave < 0) { error = errno; goto done; }
  struct termios attributes;
  if (tcgetattr(slave, &attributes) == 0) {
    /* As ghostel: backspace erases a whole UTF-8 character, C-q and C-s
       reach the program, and DEL is the erase character. */
    attributes.c_iflag |= IUTF8;
    attributes.c_iflag &= ~IXON;
    attributes.c_cc[VERASE] = 0x7f;
    tcsetattr(slave, TCSANOW, &attributes);
  }
  struct winsize size = {.ws_row = (unsigned short)rows, .ws_col = (unsigned short)columns};
  ioctl(master, TIOCSWINSZ, &size);
  if (fcntl(master, F_SETFL, O_NONBLOCK) < 0) { error = errno; goto done; }
  pid_t pid = fork();
  if (pid < 0) { error = errno; goto done; }
  if (pid == 0) {
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
    for (int s = 1; s < NSIG; ++s) signal(s, SIG_DFL);
    setsid();
    ioctl(slave, TIOCSCTTY, 0);
    dup2(slave, 0); dup2(slave, 1); dup2(slave, 2);
    for (int fd = 3; fd < 65536; ++fd) {
      if (close(fd) < 0 && errno == EBADF && fd > 1024) break;
    }
    if (cwd[0] && chdir(cwd) < 0) { const char *home = getenv("HOME"); if (home && chdir(home) < 0) {} }
    execve(path, argv, envp);
    const char message[] = "tuna terminal: cannot start the program\r\n";
    if (write(2, message, sizeof message - 1) < 0) {}
    _exit(127);
  }
  close(slave);
  slave = -1;
  out[0] = master;
  out[1] = pid;
  master = -1;
done:
  if (slave >= 0) close(slave);
  if (master >= 0) close(master);
  free(argv);
  free(envp);
  return -error;
}

/* The status of child PID: -1 while it runs, its exit code, 128 plus the
   signal that ended it, or -2 - errno when waiting fails. */
static int tuna_terminal_child_status(int pid) {
  int status;
  pid_t r;
  do { r = waitpid(pid, &status, WNOHANG); } while (r < 0 && errno == EINTR);
  if (r == 0) return -1;
  if (r < 0) return -2 - errno;
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return -1;
}

static int tuna_terminal_listen(const char *path) {
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
static int tuna_terminal_check_peer(int fd) {
  struct tuna_terminal_ucred credentials;
  socklen_t length = sizeof credentials;
  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) < 0) return -errno;
  return credentials.uid == getuid() ? 0 : -EPERM;
}

static int tuna_terminal_accept(int listener) {
  int fd = accept4(listener, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
  if (fd < 0) return -errno;
  int r = tuna_terminal_check_peer(fd);
  if (r < 0) { close(fd); return r; }
  return fd;
}

static int tuna_terminal_connect(const char *path) {
  struct sockaddr_un address = {.sun_family = AF_UNIX};
  if (strlen(path) >= sizeof address.sun_path) return -ENAMETOOLONG;
  strcpy(address.sun_path, path);
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return -errno;
  if (connect(fd, (struct sockaddr *)&address, sizeof address) < 0) { int e = errno; close(fd); return -e; }
  int r = tuna_terminal_check_peer(fd);
  if (r < 0 || fcntl(fd, F_SETFL, O_NONBLOCK) < 0) { int e = r < 0 ? -r : errno; close(fd); return -e; }
  return fd;
}

/* Make folder PATH if it does not exist; then it must be a folder, not a
   link, owned by this user and closed to others (mode 0700). */
static int tuna_terminal_private_directory(const char *path) {
  if (mkdir(path, 0700) < 0 && errno != EEXIST) return -errno;
  struct stat s;
  if (lstat(path, &s) < 0) return -errno;
  if (!S_ISDIR(s.st_mode) || s.st_uid != getuid()) return -EPERM;
  if ((s.st_mode & 0077) && chmod(path, 0700) < 0) return -errno;
  return 0;
}

static int tuna_terminal_redirect(const char *log) {
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

;;; Programs on pseudo-terminals

(def-C-lambda %spawn (UTF-8-string scheme-object int int UTF-8-string int int scheme-object) int
  "___return(tuna_terminal_spawn(___arg1, (char *)___BODY_AS(___arg2, ___tSUBTYPED), ___arg3, ___arg4,
                                 ___arg5, ___arg6, ___arg7, (int32_t *)___BODY_AS(___arg8, ___tSUBTYPED)));")
(def-C-lambda %resize (int int int int int) int
  "struct winsize size = {.ws_row = ___arg3, .ws_col = ___arg2, .ws_xpixel = ___arg4, .ws_ypixel = ___arg5};
   ___return(ioctl(___arg1, TIOCSWINSZ, &size) < 0 ? -errno : 0);")
(def-C-lambda %foreground (int) int
  "pid_t group;
   ___return(ioctl(___arg1, TIOCGPGRP, &group) < 0 ? -errno : group);")
(def-C-lambda %child-status (int) int "tuna_terminal_child_status")
(def-C-lambda %signal-group (int int) int
  "___return((kill(-___arg1, ___arg2) == 0 || kill(___arg1, ___arg2) == 0 || errno == ESRCH) ? 0 : -errno);")
(def-C-lambda current-user-id () int "___return(getuid());")
(def-C-lambda current-process-id () int "___return(getpid());")
(def-C-lambda %setsid () int "___return(setsid() < 0 ? -errno : 0);")
;; Gambit reaps every child on SIGCHLD to find its own processes' status,
;; which would lose the status of a program started here.
(def-C-lambda %default-child-signal () int "___return(signal(SIGCHLD, SIG_DFL) == SIG_ERR ? -errno : 0);")
(def-C-lambda %redirect (UTF-8-string) int "tuna_terminal_redirect")
(def-C-lambda %private-directory (UTF-8-string) int "tuna_terminal_private_directory")
(def-C-lambda %listen (UTF-8-string) int "tuna_terminal_listen")
(def-C-lambda %accept (int) int "tuna_terminal_accept")
(def-C-lambda %connect (UTF-8-string) int "tuna_terminal_connect")
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
;; The local time SECONDS after the epoch names, as YYYY-MM-DD HH:MM.
(def-C-lambda local-time-text (int64) char-string
  "static char text[32];
   time_t when = (time_t)___arg1;
   struct tm local;
   if (localtime_r(&when, &local) == NULL || strftime(text, sizeof text, \"%Y-%m-%d %H:%M\", &local) == 0)
     text[0] = 0;
   ___return(text);")
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

;; STRINGS packed as NUL-terminated UTF-8, one after another.
(def (packed-strings (strings : :list)) => :u8vector
  (apply u8vector-append
         (map (lambda ((s : :string)) (u8vector-append (string->utf8 s) (u8vector 0))) strings)))

;; Start PROGRAM, an absolute path, with ARGUMENTS (its argv, the first
;; being its name) and ENVIRONMENT ("NAME=value" strings) in DIRECTORY
;; ("" for this process's), on a new pseudo-terminal of COLUMNS x ROWS:
;; (MASTER-FD . PID).
(def (spawn-on-pty (program : :string) (arguments : :list) (environment : :list)
                   (directory : :string) (columns : :fixnum) (rows : :fixnum))
  => :pair
  (let ((out (make-s32vector 2 -1))
        (blob (packed-strings (append arguments environment))))
    (check "Cannot start the program on a pseudo-terminal"
           (%spawn program blob (length arguments) (length environment) directory columns rows out))
    (cons (s32vector-ref out 0) (s32vector-ref out 1))))

;; Tell the pseudo-terminal at FD its size, which signals its program.
(def (pty-resize (fd : :fixnum) (columns : :fixnum) (rows : :fixnum)
                 (width : :fixnum) (height : :fixnum))
  => :fixnum
  (%resize fd columns rows (fxmin width 65535) (fxmin height 65535)))

;; The process group in the foreground of the pseudo-terminal at FD, or
;; -errno.
(def (pty-foreground-group (fd : :fixnum)) => :fixnum
  (%foreground fd))

;; Child PID's status: #f while it runs, else its exit code, or 128 plus
;; the signal that ended it.
(def (child-status (pid : :fixnum)) => (Maybe :fixnum)
  (let (status (%child-status pid))
    (cond
     ((fx= status -1) #f)
     ((fx< status -1) 255)            ; no such child any more
     (else status))))

;; Send SIGNAL to process group PID (or, failing that, the process).
(def (signal-group (pid : :fixnum) (signal : :fixnum)) => :fixnum
  (%signal-group pid signal))

;; Make this process the leader of a new session, unless it already is.
(def (start-session) => :void
  (%setsid)
  (void))

(def (default-child-signal) => :void
  (check "Cannot reset SIGCHLD" (%default-child-signal))
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
  (FileDevice (__open-raw-device 'terminal fd DIRECTION-INOUT) fd DIRECTION-INOUT name))

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
