;;; The system calls a terminal needs, for the helper program and the
;;; terminal plugin (ADR 18): starting a program on a pseudo-terminal,
;;; resizing it, and waiting for and signalling it. The master is read and
;;; written as a raw device of the process library (:tuna/lib/unix), which
;;; also has the private sockets.
;;;
;;; Gambit is not used to start the program because its pseudo-terminal
;;; option is unreliable and its process ports do not make the program a
;;; session leader with the terminal as its controlling terminal; the C
;;; here forks and calls only async-signal-safe functions in the child.
prelude: :gerbil/core

(import :std/ffi
        (only-in :tuna/lib/unix errno-name))
(export spawn-on-pty
        pty-resize
        pty-foreground-group
        child-status
        signal-group
        default-child-signal
        local-time-text)

(C-ffi-macrology)
(C-include "<errno.h>" "<fcntl.h>" "<signal.h>" "<stdint.h>" "<stdlib.h>" "<string.h>"
           "<termios.h>" "<unistd.h>" "<sys/ioctl.h>" "<sys/types.h>" "<sys/wait.h>" "<time.h>")

(C-declare #<<END-C
/* Declared here rather than through _GNU_SOURCE, which the static build of
   the helper program does not pass to the compiler. */
extern int posix_openpt(int);
extern int grantpt(int);
extern int unlockpt(int);
extern int ptsname_r(int, char *, size_t);

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
;; Gambit reaps every child on SIGCHLD to find its own processes' status,
;; which would lose the status of a program started here.
(def-C-lambda %default-child-signal () int "___return(signal(SIGCHLD, SIG_DFL) == SIG_ERR ? -errno : 0);")
;; The local time SECONDS after the epoch names, as YYYY-MM-DD HH:MM.
(def-C-lambda local-time-text (int64) char-string
  "static char text[32];
   time_t when = (time_t)___arg1;
   struct tm local;
   if (localtime_r(&when, &local) == NULL || strftime(text, sizeof text, \"%Y-%m-%d %H:%M\", &local) == 0)
     text[0] = 0;
   ___return(text);")

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

(def (default-child-signal) => :void
  (check "Cannot reset SIGCHLD" (%default-child-signal))
  (void))
