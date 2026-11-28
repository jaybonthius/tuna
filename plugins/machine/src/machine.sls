#!tuna
(import (sampler) (metrics) (jobs) (options) (tables) (machine data))

(define (%restart-proc-sources root)
  (for-each sampler:restart! (list cpu memory load pressure disks file-systems network)))

(define (%restart-sys-sources root)
  (for-each sampler:restart! (list cpufreq gpu)))

(options:define-option proc-root "/proc" string? "Where the kernel's process files are." %restart-proc-sources)

(options:define-option sys-root "/sys" string? "Where the kernel's device files are." %restart-sys-sources)

(options:define-option disk-filter (lambda (name) #t) procedure?
  "Takes a disk's name, such as \"nvme0n1\", and returns true to record it.")

(options:define-option network-filter (lambda (name) #t) procedure?
  "Takes an interface's name, such as \"enp2s0\", and returns true to record it. Docker's veth and br- interfaces are most of the interfaces on a busy machine, and each is a series.")

(options:define-option file-system-filter (lambda (point) #t) procedure?
  "Takes a mount point, such as \"/home\", and returns true to record it.")

(tables:define-table gpu-attributes
  "Maps the name of a file in a graphics card's device folder to the metric it fills and the scale from the file's number to the metric's unit, as (metric . scale).")

(define (%record! m labels value time)
  (when value (metrics:record! m labels value time)))

(define (%record-cpu time data)
  (%record! cpu-usage '() (cpu-reading-usage data) time)
  (for-each (lambda (core) (%record! cpu-core-usage (list (car core)) (cdr core) time)) (cpu-reading-cores data))
  (for-each (lambda (mode) (%record! cpu-mode-share (list (car mode)) (cdr mode) time)) (cpu-reading-modes data)))

(define (%record-cpufreq time data)
  (for-each (lambda (f) (%record! cpu-frequency (list (car f)) (cdr f) time)) data))

(define (%record-memory time data)
  (%record! memory-total '() (memory-reading-total data) time)
  (%record! memory-available '() (memory-reading-available data) time)
  (%record! memory-free '() (memory-reading-free data) time)
  (%record! memory-cached '() (memory-reading-cached data) time)
  (%record! memory-buffers '() (memory-reading-buffers data) time)
  (%record! memory-used '() (memory-reading-used data) time)
  (%record! swap-total '() (memory-reading-swap-total data) time)
  (%record! swap-free '() (memory-reading-swap-free data) time))

(define (%record-load time data)
  (%record! load-average-1 '() (load-reading-one data) time)
  (%record! load-average-5 '() (load-reading-five data) time)
  (%record! load-average-15 '() (load-reading-fifteen data) time)
  (%record! tasks-running '() (load-reading-running data) time))

(define (%record-pressure time data)
  (for-each
    (lambda (stall)
      (let-values ([(some full)
                    (case (stall-resource stall)
                      [(cpu) (values cpu-pressure-some cpu-pressure-full)]
                      [(memory) (values memory-pressure-some memory-pressure-full)]
                      [(io) (values io-pressure-some io-pressure-full)])])
        (%record! some '() (stall-some stall) time)
        (%record! full '() (stall-full stall) time)))
    data))

(define (%record-disks time data)
  (for-each
    (lambda (d)
      (let ([labels (list (disk-rates-name d))])
        (when ((disk-filter) (disk-rates-name d))
          (%record! disk-read labels (disk-rates-read d) time)
          (%record! disk-write labels (disk-rates-write d) time)
          (%record! disk-busy labels (disk-rates-busy d) time))))
    data))

(define (%record-file-systems time data)
  (for-each
    (lambda (f)
      (let ([labels (list (mount-space-point f))])
        (when ((file-system-filter) (mount-space-point f))
          (%record! file-system-size labels (mount-space-size f) time)
          (%record! file-system-free labels (mount-space-free f) time)
          (%record! file-system-available labels (mount-space-available f) time))))
    data))

(define (%record-network time data)
  (for-each
    (lambda (n)
      (let ([labels (list (interface-rates-name n))])
        (when ((network-filter) (interface-rates-name n))
          (%record! network-receive labels (interface-rates-receive n) time)
          (%record! network-transmit labels (interface-rates-transmit n) time))))
    data))

(define (%record-gpu time data)
  (for-each
    (lambda (v)
      (let ([entry (tables:ref gpu-attributes (card-value-attribute v))])
        (when entry
          (%record! (car entry) (list (card-value-card v)) (* (card-value-value v) (cdr entry)) time))))
    data))

(jobs:define-worker (%cpu-reader root emit receive)
  (import (sampler reading) (machine readings))
  (reading-loop cpu-reading root emit receive))

(jobs:define-worker (%cpufreq-reader root emit receive)
  (import (sampler reading) (machine readings))
  (reading-loop cpufreq-reading root emit receive))

(jobs:define-worker (%memory-reader root emit receive)
  (import (sampler reading) (machine readings))
  (reading-loop memory-reading root emit receive))

(jobs:define-worker (%load-reader root emit receive)
  (import (sampler reading) (machine readings))
  (reading-loop load-reading root emit receive))

(jobs:define-worker (%pressure-reader root emit receive)
  (import (sampler reading) (machine readings))
  (reading-loop pressure-reading root emit receive))

(jobs:define-worker (%disks-reader root emit receive)
  (import (sampler reading) (machine readings))
  (reading-loop disks-reading root emit receive))

(jobs:define-worker (%file-systems-reader root emit receive)
  (import (sampler reading) (machine readings))
  (reading-loop file-systems-reading root emit receive))

(jobs:define-worker (%network-reader root emit receive)
  (import (sampler reading) (machine readings))
  (reading-loop network-reading root emit receive))

(jobs:define-worker (%gpu-reader input emit receive)
  (import (sampler reading) (machine readings))
  (reading-loop gpu-reading input emit receive))

(define (%gpu-input) (cons (sys-root) (map car (tables:entries gpu-attributes))))

(sampler:define-source cpu %cpu-reader proc-root %record-cpu)
(sampler:define-source cpufreq %cpufreq-reader sys-root %record-cpufreq)
(sampler:define-source memory %memory-reader proc-root %record-memory)
(sampler:define-source load %load-reader proc-root %record-load)
(sampler:define-source pressure %pressure-reader proc-root %record-pressure)
(sampler:define-source disks %disks-reader proc-root %record-disks)
(sampler:define-source file-systems %file-systems-reader proc-root %record-file-systems)
(sampler:define-source network %network-reader proc-root %record-network)
(sampler:define-source gpu %gpu-reader %gpu-input %record-gpu)

(metrics:define-metric cpu-usage (unit ratio) (source cpu)
  (documentation "Share of all processors' time spent busy."))
(metrics:define-metric cpu-core-usage (unit ratio) (labels cpu) (source cpu)
  (documentation "Share of one processor's time spent busy."))
(metrics:define-metric cpu-mode-share (unit ratio) (labels mode) (source cpu)
  (documentation "Share of all processors' time spent in each mode: user, nice, system, idle, iowait, irq, softirq and steal; the shares sum to 1."))
(metrics:define-metric cpu-frequency (unit hertz) (labels cpu) (source cpufreq)
  (documentation "A processor's current frequency."))
(metrics:define-metric memory-total (unit bytes) (source memory) (documentation "Memory the kernel manages."))
(metrics:define-metric memory-available (unit bytes) (source memory)
  (documentation "Memory available to start programs without swapping, as the kernel estimates it."))
(metrics:define-metric memory-free (unit bytes) (source memory) (documentation "Memory not used for anything."))
(metrics:define-metric memory-cached (unit bytes) (source memory) (documentation "Memory holding the page cache."))
(metrics:define-metric memory-buffers (unit bytes) (source memory) (documentation "Memory holding block-device buffers."))
(metrics:define-metric memory-used (unit bytes) (source memory) (documentation "Total memory less available memory."))
(metrics:define-metric swap-total (unit bytes) (source memory) (documentation "Swap space."))
(metrics:define-metric swap-free (unit bytes) (source memory) (documentation "Swap space not in use."))
(metrics:define-metric load-average-1 (unit count) (source load)
  (documentation "Tasks running or waiting to run, averaged over a minute."))
(metrics:define-metric load-average-5 (unit count) (source load)
  (documentation "Tasks running or waiting to run, averaged over five minutes."))
(metrics:define-metric load-average-15 (unit count) (source load)
  (documentation "Tasks running or waiting to run, averaged over fifteen minutes."))
(metrics:define-metric tasks-running (unit count) (source load) (documentation "Tasks running now."))
(metrics:define-metric cpu-pressure-some (unit ratio) (source pressure)
  (documentation "Share of the time in which some tasks waited for a processor."))
(metrics:define-metric cpu-pressure-full (unit ratio) (source pressure)
  (documentation "Share of the time in which every non-idle task waited for a processor."))
(metrics:define-metric memory-pressure-some (unit ratio) (source pressure)
  (documentation "Share of the time in which some tasks stalled on memory."))
(metrics:define-metric memory-pressure-full (unit ratio) (source pressure)
  (documentation "Share of the time in which every non-idle task stalled on memory."))
(metrics:define-metric io-pressure-some (unit ratio) (source pressure)
  (documentation "Share of the time in which some tasks stalled on input and output."))
(metrics:define-metric io-pressure-full (unit ratio) (source pressure)
  (documentation "Share of the time in which every non-idle task stalled on input and output."))
(metrics:define-metric disk-read (unit bytes-per-second) (labels disk) (source disks) (documentation "Bytes read from a disk."))
(metrics:define-metric disk-write (unit bytes-per-second) (labels disk) (source disks)
  (documentation "Bytes written to a disk."))
(metrics:define-metric disk-busy (unit ratio) (labels disk) (source disks)
  (documentation "Share of the time in which a disk had input or output in flight."))
(metrics:define-metric file-system-size (unit bytes) (labels mount) (source file-systems)
  (documentation "A mounted file system's size."))
(metrics:define-metric file-system-free (unit bytes) (labels mount) (source file-systems)
  (documentation "A mounted file system's free space."))
(metrics:define-metric file-system-available (unit bytes) (labels mount) (source file-systems)
  (documentation "A mounted file system's space available to an unprivileged user."))
(metrics:define-metric network-receive (unit bytes-per-second) (labels interface) (source network)
  (documentation "Bytes received on a network interface."))
(metrics:define-metric network-transmit (unit bytes-per-second) (labels interface) (source network)
  (documentation "Bytes sent on a network interface."))
(metrics:define-metric gpu-busy (unit ratio) (labels card) (source gpu)
  (documentation "Share of the time a graphics card was busy."))
(metrics:define-metric gpu-memory-used (unit bytes) (labels card) (source gpu)
  (documentation "A graphics card's memory in use."))
(metrics:define-metric gpu-memory-total (unit bytes) (labels card) (source gpu)
  (documentation "A graphics card's memory."))

(tables:set! gpu-attributes "gpu_busy_percent" (cons gpu-busy 1/100))
(tables:set! gpu-attributes "mem_info_vram_used" (cons gpu-memory-used 1))
(tables:set! gpu-attributes "mem_info_vram_total" (cons gpu-memory-total 1))
