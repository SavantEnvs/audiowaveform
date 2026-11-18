// libFuzzer harness for audiowaveform. It drives the program's own entry point -- Options::parseCommandLine
// followed by OptionHandler::run, exactly what main() does -- over the fuzzed bytes, which are staged as
// the input file in a per-process scratch directory ($TMPDIR). The command lines are fixed, one set per
// target (HARNESS_MODE); only the file contents come from the fuzzer.

#include "Options.h"
#include "OptionHandler.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <streambuf>
#include <string>
#include <unistd.h>
#include <vector>

#define MODE_MP3 1
#define MODE_AUDIO 2
#define MODE_DAT 3
#define MODE_JSON 4

#ifndef HARNESS_MODE
#error "define HARNESS_MODE to one of MODE_MP3, MODE_AUDIO, MODE_DAT, MODE_JSON"
#endif

// main() normally defines these; the program writes its messages to them.
namespace {
class NullBuf : public std::streambuf {
    public:
        int overflow(int ch) override { return ch; }
};
NullBuf null_buf;
std::ostream null_stream(&null_buf);
}

std::ostream& output_stream = null_stream;
std::ostream& error_stream = null_stream;

static std::string scratch_dir;
static std::string input_path;
static std::string output_path;

static void cleanup()
{
    unlink(input_path.c_str());
    unlink(output_path.c_str());
    rmdir(scratch_dir.c_str());
}

extern "C" int LLVMFuzzerInitialize(int*, char***)
{
    const char* tmp = getenv("TMPDIR");
    std::string tmpl = std::string(tmp != nullptr && *tmp != '\0' ? tmp : "/tmp") + "/audiowaveform-XXXXXX";
    std::vector<char> buf(tmpl.begin(), tmpl.end());
    buf.push_back('\0');

    if (mkdtemp(buf.data()) == nullptr) {
        perror("mkdtemp");
        abort();
    }

    scratch_dir = buf.data();
    input_path = scratch_dir + "/input";
    output_path = scratch_dir + "/output";
    atexit(cleanup);
    return 0;
}

static bool writeInput(const uint8_t* data, size_t size)
{
    FILE* f = fopen(input_path.c_str(), "wb");

    if (f == nullptr) {
        return false;
    }

    const bool ok = size == 0 || fwrite(data, 1, size, f) == size;

    return fclose(f) == 0 && ok;
}

// Runs "audiowaveform -q -i <input> -o <output> <extra...>" and returns whether it succeeded.
static bool run(const std::vector<std::string>& extra)
{
    unlink(output_path.c_str());

    std::vector<std::string> args = {
        "audiowaveform", "-q", "-i", input_path, "-o", output_path
    };
    args.insert(args.end(), extra.begin(), extra.end());

    std::vector<const char*> argv;

    for (const std::string& arg : args) {
        argv.push_back(arg.c_str());
    }

    bool success = false;

    Options options;

    if (options.parseCommandLine(static_cast<int>(argv.size()), argv.data())) {
        OptionHandler handler;
        success = handler.run(options);
    }

    unlink(output_path.c_str());

    return success;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
#if HARNESS_MODE == MODE_MP3
    // Input filter, NOT a library precondition: the library's contract does not exclude an empty file. It is skipped
    // because it crashes upstream: Mp3AudioFileReader::run -> ProgressReporter::update (src/ProgressReporter.cpp:69,
    // static_cast<int>(NaN), frames_/sample_rate_ is 0/0 and file_size_ is 0) -> UBSan
    // "runtime error: -nan is outside the range of representable values of type 'int'" (undefined-behavior, halting).
    // With no corpus libFuzzer's first input is empty, so without this the target dies before it iterates and
    // gate-fuzz-smoke reports "libFuzzer did not iterate". Reproducer and write-up: mayhem/fuzz_mp3/known-findings/empty-file.
    if (size == 0) {
        return -1;
    }
#elif HARNESS_MODE == MODE_DAT
    // Input filter, NOT a library precondition: the 12-byte length is not part of WaveformBuffer::load's contract. A file
    // whose header ends early (e.g. empty) is accepted as success with sample rate 0, and the rescale then aborts on
    // assert(sample_rate_ > 0) at src/WaveformRescaler.cpp:58 (SIGABRT, "Assertion `sample_rate_ > 0' failed").
    // The filter only keeps out the empty first input libFuzzer tries without a corpus (gate-fuzz-smoke reports
    // "libFuzzer did not iterate" otherwise). Longer truncated headers still reach the same asserts (:58, :60) and are
    // findings. Reproducer and write-up: mayhem/fuzz_dat/known-findings/short-file.
    if (size < 12) {
        return -1;
    }
#endif

    if (!writeInput(data, size)) {
        abort();
    }

#if HARNESS_MODE == MODE_MP3
    // MP3 -> waveform data (WaveformGenerator), then MP3 -> PNG with automatic zoom (DurationCalculator + renderer).
    if (!run({"--input-format", "mp3", "--output-format", "dat", "-z", "64", "-b", "8", "--split-channels"})) {
        return -1;
    }

    run({"--input-format", "mp3", "--output-format", "png", "-z", "auto", "-w", "128", "-h", "64"});
#elif HARNESS_MODE == MODE_AUDIO
    // libsndfile formats: WAV is sniffed from content, so the second pass reads the same bytes as FLAC/Ogg/Opus
    // and converts them to WAV.
    if (!run({"--input-format", "wav", "--output-format", "dat", "-z", "64", "-b", "8"})) {
        return -1;
    }

    run({"--input-format", "flac", "--output-format", "wav"});
#elif HARNESS_MODE == MODE_DAT
    if (!run({"--input-format", "dat", "--output-format", "txt", "-b", "8"})) {
        return -1;
    }

    run({"--input-format", "dat", "--output-format", "json"});
    run({"--input-format", "dat", "--output-format", "png", "-w", "128", "-h", "64",
         "--waveform-style", "bars", "--bar-width", "4", "--bar-gap", "2", "--split-channels"});
    run({"--input-format", "dat", "--output-format", "png", "-w", "128", "-h", "64",
         "--amplitude-scale", "auto"});
    run({"--input-format", "dat", "--output-format", "dat", "-z", "512"});
#elif HARNESS_MODE == MODE_JSON
    if (!run({"--input-format", "json", "--output-format", "dat"})) {
        return -1;
    }

    run({"--input-format", "json", "--output-format", "png", "-w", "128", "-h", "64"});
    run({"--input-format", "json", "--output-format", "json", "-z", "512"});
#endif

    return 0;
}
