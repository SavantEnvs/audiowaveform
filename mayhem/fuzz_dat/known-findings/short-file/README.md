# A .dat file shorter than its 12-byte header is accepted as a valid waveform with sample rate 0

Reproducer: `short.dat` (1 byte). The shipped `fuzz_dat` and `fuzz_dat-standalone` skip it (see the end), so to
see the crash change the `size < 12` filter in `mayhem/harness.cpp` to `false` and rebuild, or run
`audiowaveform -i short.dat --input-format dat -o out.dat --output-format dat -z 512` on a build with assertions
enabled.

Report: `fuzz_dat-standalone: src/WaveformRescaler.cpp:58: void WaveformRescaler::rescale(const WaveformBuffer &,
WaveformBuffer &, int): Assertion 'sample_rate_ > 0' failed.` (SIGABRT; not a sanitizer report, an `assert`).

Cause: `WaveformBuffer::load` enables stream exceptions, and its `catch` block treats an EOF in the middle of the
header as success. A file of fewer than 12 bytes therefore "loads" as a buffer with sample rate 0, 0 samples
per pixel and no data (the CLI prints "Input scale: 0 samples/pixel"). `WaveformRescaler::rescale` then aborts on
`assert(sample_rate_ > 0)` (`src/WaveformRescaler.cpp:58`); PNG output reports "Invalid sample rate: 0 Hz" late.
A zero-length file (`empty.dat`) behaves the same.

Impact: low; abort in an assertion-enabled build on a truncated input. Fix: in `WaveformBuffer::load`, fail when
the EOF happens before the header is complete (check `sample_rate_ < 1` after the catch).

Why the harness filters it: the `size < 12` check in `mayhem/harness.cpp` is an input filter, not a library
precondition (`WaveformBuffer::load`'s contract does not require a 12-byte header). It stays because `gate-fuzz-smoke`
runs the binary with no corpus, so libFuzzer's first input is empty; without the filter the target aborts on it
before iterating and the gate reports "libFuzzer did not iterate". It is not complete: a longer truncated header
(for example `01 00 00 00 00 00 00 00 01 00 00 00`, 12 bytes) still reaches the rescaler and trips the sibling
`assert(input_samples_per_pixel > 0)` at `WaveformRescaler.cpp:60`; those are findings, not filtered.
