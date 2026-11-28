(library (sensors data)
  (export make-sensor-value sensor-value-chip sensor-value-device sensor-value-sensor sensor-value-kind
          sensor-value-attribute sensor-value-value
          make-battery-reading battery-reading-name battery-reading-charge battery-reading-energy
          battery-reading-power battery-reading-plugged battery-reading-charging battery-reading-seconds-left)
  (import (chezscheme))

  ;; A reading crosses from its worker as plain data, so each shape is a
  ;; vector, made and read only through these procedures.
  (define (make-sensor-value chip device sensor kind attribute value)
    (vector chip device sensor kind attribute value))
  (define (sensor-value-chip v) (vector-ref v 0))
  (define (sensor-value-device v) (vector-ref v 1))
  (define (sensor-value-sensor v) (vector-ref v 2))
  (define (sensor-value-kind v) (vector-ref v 3))
  (define (sensor-value-attribute v) (vector-ref v 4))
  (define (sensor-value-value v) (vector-ref v 5))

  (define (make-battery-reading name charge energy power plugged charging seconds-left)
    (vector name charge energy power plugged charging seconds-left))
  (define (battery-reading-name v) (vector-ref v 0))
  (define (battery-reading-charge v) (vector-ref v 1))
  (define (battery-reading-energy v) (vector-ref v 2))
  (define (battery-reading-power v) (vector-ref v 3))
  (define (battery-reading-plugged v) (vector-ref v 4))
  (define (battery-reading-charging v) (vector-ref v 5))
  (define (battery-reading-seconds-left v) (vector-ref v 6)))
