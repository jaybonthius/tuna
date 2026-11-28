# Fixtures

- `proc-1/`, `proc-2/`: the files the plugin reads from `/proc`, copied from a Linux 6.8 x86-64 machine with 16 processors two seconds apart, unedited: a real pair of readings.
- `sys/`: the processors' frequency and topology files and the `amdgpu` card, with its links, copied from the same machine, unedited.

Tests make variants of these in their home, each changing one file as the test says.
