# Zero-length MP3: NaN converted to int (UBSan)

Reproducer: `empty.mp3` (0 bytes). The shipped `fuzz_mp3` and `fuzz_mp3-standalone` skip it (see the end), so to
see the crash change the `size == 0` filter in `mayhem/harness.cpp` to `false` and rebuild, or run
`audiowaveform -i empty.mp3 --input-format mp3 -o out.dat --output-format dat` from an UBSan build.

Sanitizer report (UBSan, halting):
`src/ProgressReporter.cpp:69:30: runtime error: -nan is outside the range of representable values of type 'int'`
(`SUMMARY: UndefinedBehaviorSanitizer: undefined-behavior src/ProgressReporter.cpp:69:30`).

Cause: `Mp3AudioFileReader::run` computes `frames_ / sample_rate_` as `0.0 / 0.0` when no frame was decoded.
With an empty file `file_size_` is 0, so `ProgressReporter::update` takes its seconds branch and executes
`static_cast<int>(seconds)` on NaN (`src/ProgressReporter.cpp:69`), which is undefined behavior.

Impact: low; undefined conversion on a degenerate input. Fix: guard `sample_rate_ == 0` before computing
`seconds`, or check `std::isfinite(seconds)` in `ProgressReporter::update`.

Why the harness filters it: the `size == 0` check in `mayhem/harness.cpp` is an input filter, not a library
precondition (nothing in the library's contract excludes an empty file). It stays because `gate-fuzz-smoke` runs
the binary with no corpus, so libFuzzer's first input is empty; without the filter the target crashes on it before
iterating and the gate reports "libFuzzer did not iterate".
