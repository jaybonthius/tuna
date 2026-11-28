# Fixtures

- `sys/`: the six hardware-monitor chips of a Linux 6.8 x86-64 machine (`acpitz`, two `nvme`, `k10temp`, `iwlwifi_1`, `amdgpu`) and the device folders their links lead to, copied unedited.
- `battery/`, `mains/`: written by hand from Linux's `Documentation/ABI/testing/sysfs-class-power`, since the machine has no battery: a battery `BAT0` discharging, alone and beside a mains supply `AC0` that is online.
