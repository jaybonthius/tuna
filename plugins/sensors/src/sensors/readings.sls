(library (sensors readings)
  (export hwmon-reading batteries-reading)
  (import (chezscheme) (sysfs) (sensors data))

  (define recorded-kinds
    (list (sensor-kind temperature) (sensor-kind fan) (sensor-kind voltage) (sensor-kind power) (sensor-kind current)))
  (define limits
    (list (sensor-attribute max) (sensor-attribute min) (sensor-attribute crit) (sensor-attribute lcrit)))

  ;; A power sensor may give both an input and an average; the input is
  ;; recorded, else the average, so a reading records it once.
  (define (sensor-values fs chip s)
    (let* ([kind (hwmon-sensor-kind s)]
           [name (or (hwmon-sensor-label s) (hwmon-sensor-name s))]
           [value (lambda (attribute) (hwmon-sensor-value fs s attribute))]
           [entry (lambda (attribute v)
                    (and v (make-sensor-value (hwmon-chip-name chip) (hwmon-chip-device chip) name kind attribute v)))])
      (if (memq kind recorded-kinds)
          (filter values
            (cons* (entry (sensor-attribute input) (or (value (sensor-attribute input)) (value (sensor-attribute average))))
                   (entry (sensor-attribute alarm) (value (sensor-attribute alarm)))
                   (map (lambda (limit) (entry limit (value limit))) limits)))
          '())))

  (define (hwmon-reading root kept)
    (let ([fs (make-sysfs root)])
      (values #f
        (apply append
          (map (lambda (chip) (apply append (map (lambda (s) (sensor-values fs chip s)) (hwmon-chip-sensors chip))))
               (sysfs-hwmon-chips fs))))))

  (define (battery-reading supplies b)
    (let ([plugged (power-supply-plugged supplies b)])
      (make-battery-reading
        (power-supply-name b)
        (if (and (power-supply-energy-now b) (power-supply-energy-full b) (positive? (power-supply-energy-full b)))
            (/ (power-supply-energy-now b) (power-supply-energy-full b))
            (power-supply-capacity b))
        (power-supply-energy-now b)
        (power-supply-power-now b)
        (cond
          [(eq? plugged (plugged-state plugged)) 1]
          [(eq? plugged (plugged-state unplugged)) 0]
          [else #f])
        (if (equal? (power-supply-status b) "Charging") 1 0)
        (and (eq? plugged (plugged-state unplugged)) (power-supply-seconds-left b)))))

  (define (batteries-reading root kept)
    (let ([supplies (sysfs-power-supplies (make-sysfs root))])
      (values #f
        (map (lambda (b) (battery-reading supplies b))
             (filter (lambda (s) (equal? (power-supply-type s) "Battery")) supplies))))))
