# Fixtures

Each folder is laid out as `/proc` is. `stat`, `meminfo`, `uptime`, `tty/drivers` and process `1483`, named `(sd-pam)`, are copied from a Linux 6.8 x86-64 machine, unedited. Process `4242` is written by hand from `1483`'s files, with ids no account has: in `proc-a` its command line is `worker --first` and its cgroup `/first.slice`; in `proc-b` they are `worker --second` and `/second.slice` and its user id differs. `proc-zero` is `proc-a` with an uptime equal to the processes' start, so they have run for no time.
