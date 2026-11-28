(library (machine data)
  (export make-cpu-reading cpu-reading-usage cpu-reading-cores cpu-reading-modes
          make-memory-reading memory-reading-total memory-reading-available memory-reading-free
          memory-reading-cached memory-reading-buffers memory-reading-used memory-reading-swap-total
          memory-reading-swap-free
          make-load-reading load-reading-one load-reading-five load-reading-fifteen load-reading-running
          make-stall stall-resource stall-some stall-full
          make-disk-rates disk-rates-name disk-rates-read disk-rates-write disk-rates-busy
          make-mount-space mount-space-point mount-space-size mount-space-free mount-space-available
          make-interface-rates interface-rates-name interface-rates-receive interface-rates-transmit
          make-card-value card-value-card card-value-attribute card-value-value)
  (import (chezscheme))

  ;; A reading crosses from its worker as plain data, so each shape is a
  ;; vector, made and read only through these procedures.
  (define (make-cpu-reading usage cores modes) (vector usage cores modes))
  (define (cpu-reading-usage v) (vector-ref v 0))
  (define (cpu-reading-cores v) (vector-ref v 1))
  (define (cpu-reading-modes v) (vector-ref v 2))

  (define (make-memory-reading total available free cached buffers used swap-total swap-free)
    (vector total available free cached buffers used swap-total swap-free))
  (define (memory-reading-total v) (vector-ref v 0))
  (define (memory-reading-available v) (vector-ref v 1))
  (define (memory-reading-free v) (vector-ref v 2))
  (define (memory-reading-cached v) (vector-ref v 3))
  (define (memory-reading-buffers v) (vector-ref v 4))
  (define (memory-reading-used v) (vector-ref v 5))
  (define (memory-reading-swap-total v) (vector-ref v 6))
  (define (memory-reading-swap-free v) (vector-ref v 7))

  (define (make-load-reading one five fifteen running) (vector one five fifteen running))
  (define (load-reading-one v) (vector-ref v 0))
  (define (load-reading-five v) (vector-ref v 1))
  (define (load-reading-fifteen v) (vector-ref v 2))
  (define (load-reading-running v) (vector-ref v 3))

  (define (make-stall resource some full) (vector resource some full))
  (define (stall-resource v) (vector-ref v 0))
  (define (stall-some v) (vector-ref v 1))
  (define (stall-full v) (vector-ref v 2))

  (define (make-disk-rates name read-rate write-rate busy) (vector name read-rate write-rate busy))
  (define (disk-rates-name v) (vector-ref v 0))
  (define (disk-rates-read v) (vector-ref v 1))
  (define (disk-rates-write v) (vector-ref v 2))
  (define (disk-rates-busy v) (vector-ref v 3))

  (define (make-mount-space point size free available) (vector point size free available))
  (define (mount-space-point v) (vector-ref v 0))
  (define (mount-space-size v) (vector-ref v 1))
  (define (mount-space-free v) (vector-ref v 2))
  (define (mount-space-available v) (vector-ref v 3))

  (define (make-interface-rates name receive transmit) (vector name receive transmit))
  (define (interface-rates-name v) (vector-ref v 0))
  (define (interface-rates-receive v) (vector-ref v 1))
  (define (interface-rates-transmit v) (vector-ref v 2))

  (define (make-card-value card attribute value) (vector card attribute value))
  (define (card-value-card v) (vector-ref v 0))
  (define (card-value-attribute v) (vector-ref v 1))
  (define (card-value-value v) (vector-ref v 2)))
