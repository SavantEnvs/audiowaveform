# `audiowaveform -z N` on a .dat/.json input that already has N or more samples per pixel: assert / garbage output

Reproducer: `zoom.dat` (35 bytes, 16384 samples/pixel). Run `fuzz_dat-standalone zoom.dat` on a build with
assertions enabled, or `audiowaveform -i zoom.dat --input-format dat -o out.dat --output-format dat -z 512`.

Cause: `OptionHandler::rescaleWaveformData` (the data-to-data path, `src/OptionHandler.cpp` ~line 577) calls
`WaveformRescaler::rescale` without the check the image path has ("Invalid zoom, minimum: N"). The rescaler requires
`output_samples_per_pixel > input_samples_per_pixel` and aborts on that `assert` (`src/WaveformRescaler.cpp:61`).
With NDEBUG (upstream's release build) there is no abort: the CLI exits 0 and writes a bogus buffer ("Generated 224
points" from 7 input points).

Impact: low to medium; abort with assertions on, silently wrong output without. Fix: reject
`output_samples_per_pixel <= input_samples_per_pixel` in `rescaleWaveformData` as `renderWaveformImage` does.
