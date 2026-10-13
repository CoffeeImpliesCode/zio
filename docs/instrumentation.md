# Runtime instrumentation

Build with `zig build examples -Dinstrument=true`. The default is `false`: hooks and
per-task trace data are compile-time eliminated. A root module can also set
`pub const zio_options: zio.Options = .{ .instrument = true };`.

Tracing starts when the first runtime is initialized, only when `ZIO_PROFILE=1`.
Unset, empty, or any other value leaves the tracing session inactive: no output,
writer thread, or buffers are created. The last runtime's `deinit` drains the
writer, closes files, and records the session end. Join external threads that use
instrumentation before deinitializing the last runtime.

```sh
zig build examples -Dexample=trace-demo -Dinstrument=true
ZIO_PROFILE=1 ./zig-out/bin/trace-demo
```

## Output layout

The working directory receives `.zio/<realtime_nanoseconds>/process.dump` and
`<os_thread_id>-<session_thread_index>.dump` for each event-producing thread. A
collision appends `-<pid>` to the directory name. Directory permissions are 0700;
files are 0600. Trace messages, paths, and user labels can contain private data.
The trace-local index prevents OS thread-id reuse from merging threads.

The process file records the executable path, runtime address of
`zio_trace_anchor`, operation names, clock calibration, and final dropped count.
Thread files record thread kind, executor identity, and independently decodable,
consecutively numbered chunks. Executors and blocking-pool workers flush on exit;
other threads flush at session end. File I/O is raw OS I/O, never zio I/O.

## Events and protocol

`src/instrument/format.zig` defines version 1 of the binary protocol and provides
`FileReader`, `parseChunk`, and `EventIterator`. Files start with a 40-byte
`ZIOTRACE` header. Records carry a kind byte, ULEB128 payload length, and payload.
Chunks carry thread index, sequence number, base timestamp, then events with a
kind byte and timestamp delta. Integers use ULEB128; signed values use zigzag.
Strings are length-prefixed bytes, not NUL-terminated. Unknown records can be
skipped; unknown events terminate decoding of their chunk. A crash can leave a
truncated final record; earlier complete records remain readable.

`task_begin` and `task_end` delimit actual coroutine execution, including direct
coroutine-to-coroutine switches. End reasons distinguish runnable yield, waiting,
and completion. Main-task execution is recorded separately from scheduler work;
worker executors do not execute their synthetic main task. Task ids are unique
within a session and remain unchanged during migration. Creation records carry
parent and group identity; wake records identify the emitting thread.

Park events enclose executor idle handling. Poll events enclose only backend
polls, not callback dispatch: timeout zero means a nonblocking check; the maximum
u64 represents an unbounded wait. Loop wake events mean a backend wake was
actually issued. Completion addresses identify I/O submissions and finishes;
addresses may be reused after completion. Blocking work records distinguish queue
submission and worker execution. User zones are nested begin/end events with a
source-location definition preceding first use on each thread. Plots use signed
64-bit values.

## Function attribution

Native spawn wrappers emit the user function address. Creation also captures a
bounded spawn-side stack. The first suspension captures return addresses from
the coroutine's own frame-pointer chain, bounded by its stack allocation. These
stacks expose user callers of generic `std.Io` async/concurrent wrappers. Stack
attribution in release builds requires frame pointers on both the executable
and zio modules: set `.omit_frame_pointer = false` in their module options (or
assign `exe.root_module.omit_frame_pointer = false` and
`zio_module.omit_frame_pointer = false` in the build script). Keep DWARF for
source lines. Inlining can still remove frames.

The tracer walks only increasing frame pointers inside known stack bounds; it
never loads DWARF or performs CFI unwinding. Native stack bounds are queried once
per registered thread on Linux/Darwin. Unknown bounds skip stack capture. With
omitted frame pointers, walks can stop early or recover no useful caller, so
`std.Io` tasks may retain their generic wrapper name. Explicit native function
addresses continue to work. The anchor permits relocation of PIE addresses;
the analyzer falls back from an explicit function to suspension/spawn stacks,
then the generic entry address.

## User markers

```zig
const span = zio.instrument.zone(@src());
defer span.end();
zio.instrument.message("batch started");
zio.instrument.plot("queue depth", 12);
```

Zones follow their task across migration in the analyzer. All three APIs are
no-ops when compiled out or inactive.

## Overhead

The active fast path reads the hardware counter (RDTSC on x86_64, CNTVCT on
AArch64; monotonic nanoseconds otherwise) and encodes into a thread-local 64 KiB
buffer. Each registered thread owns two buffers. Full chunks are handed to one
background writer. Public hooks inline only a likely-inactive flag check; active
encoding and stack capture are out-of-line. Slice-free events encode in one pass,
using a compile-time size bound; strings/stacks use an exact-length check.
Apart from active/generation loads, ordinary events need no lock or atomic.
Rollover uses an atomic handoff. The writer blocks on a futex until a chunk or
shutdown notification, with a calibration timeout of about one second.
Producers wait on their own buffer's futex if the spare is still in use; those
waits have flush brackets. Registration, source definitions, stack capture, and
lifecycle management are intentionally slower control paths. Thread-begin/end
events bound the observed lifetime, including idle blocking-worker time.
Calibration pairs ticks with monotonic time at start, approximately once a
second, and at end. Profiling writes real data and perturbs the measured program:
compare inactive and active ReleaseFast builds for the actual workload and disk.

For one x86_64 Linux ReleaseFast sample, two tasks each yielded 2,000,000 times on
one executor. Five interleaved runs per mode, pinned to two physical cores on one
socket (one available for the writer), produced these times. The timing region
ends before final runtime teardown:

| Build / environment | Minimum ns/yield-switch | Median ns/yield-switch |
| --- | ---: | ---: |
| `instrument=false` | 47.04 | 47.28 |
| `instrument=true`, `ZIO_PROFILE` unset | 48.79 | 49.10 |
| `instrument=true`, `ZIO_PROFILE=1` | 115.85 | 129.37 |

Inactive tracing added 1.83 ns/switch at the medians. Compared with the previous
inline/pre-sized encoder, median tracing-added cost fell from 62.45 to 40.13
ns/event (subtract the inactive baseline, then divide by two task events per
switch). Total active cost, including the runtime, fell from 91.86 to 64.69
ns/event. The preserved previous binary used 500,000 yields per task; all values
are normalized by its switch count.

The median active trace recorded 8,000,033 events in 517.693 ms of trace wall
time: 15.45 million events/s and 123.67 MB/s of dumps (decimal MB). Dump size was
64,022,997 bytes, with no drops or decode errors. Perf samples placed most tracing
cycles in task begin/end hooks; timestamp reads and remaining LEB128 stores/loops
dominate their active work. These are sample measurements, not a portable
overhead guarantee: scheduler, CPU contention, and storage matter.

## Analyzing a trace

Build the offline analyzer separately; it does not depend on an instrumented
runtime:

```sh
zig build zio-trace
zio-trace info /path/to/.zio/SESSION
zio-trace util --bins 300 -o utilization.svg /path/to/.zio/SESSION
zio-trace stats /path/to/.zio/SESSION
zio-trace perfetto --flows -o trace.json /path/to/.zio/SESSION
```

Without a session argument, the analyzer selects the newest timestamp directory
under the current directory's `.zio`. `--exe PATH` overrides the executable
recorded in the trace. Keep the matching executable and its debug information:
rebuilding at the same path can make recorded addresses resolve incorrectly.

`info` reports the clock fit, observed duration, threads, dropped events, decode
errors, and incomplete intervals. Files ending mid-record retain all earlier
complete records. Unknown record kinds are skipped; an unknown event ends only
its chunk. Chunks are reordered by sequence number before event decoding.
Nanoseconds come from a least-squares calibration fit, or a single calibration
point and the nominal clock frequency.

`util` writes a self-contained, 1200-pixel-wide SVG and prints a thread table.
Executor rows split each bin into task, scheduler, nonblocking poll, blocking
poll, and tracing-flush time. Busy means task + scheduler + nonblocking poll;
blocking workers use work / observed wall time, with the rest of their lifetime
counted as idle (apart from trace-flush overhead). `thread_begin` and `thread_end`
bound each thread's observed lifetime, including idle time before its first job
and after its last. Older traces without these markers fall back to first/last
events; either missing boundary falls back independently. Other threads display
point events rather than a utilization estimate. The row background and binned
activity are clipped to the observed interval; time outside it is blank.
Bins may average very short activity bursts.

`stats` groups task slices by resolved function name and reports run time,
wake-to-run latency, and completed-task lifetime. It also reports per-thread
states, I/O submit-to-complete latency by operation, blocking queue/run time,
steals, parks, zones, and plot summaries. Durations are in microseconds except
the explicitly labelled thread-state table. Percentiles use the nearest rank.
Unmatched operation endpoints and unfinished lifetimes are not latency samples.

Source-location definitions apply process-wide. Zone stacks follow tasks across
thread migration; markers outside a running task use the emitting thread's
stack. Zone wall duration includes suspension time. Task-zone on-CPU duration
sums the task's running time within the zone; thread-only zones have no task
on-CPU sample. Zone statistics aggregate by source location across all threads.

Task naming prefers an explicit user function, then the first non-runtime
suspension-stack frame, then a spawn caller rendered as `spawned at file:line`,
then the entry symbol, and finally a hexadecimal address. Executor main tasks
are labelled `main (executor N)`. Runtime-frame filtering is heuristic: it skips
`std`/`zio` namespaces, Zig `lib/std/`, and zio `src/` paths (including relative
`src/` paths). Unusual source layouts or optimization can weaken attribution.
Missing symbols do not prevent timeline or utilization analysis.

Open `trace.json` in [Perfetto](https://ui.perfetto.dev/) or
`chrome://tracing`. Each traced thread has its own track with task slices,
poll/park/flush intervals, messages, plot counters, and thread-only zones.
Task zones use nestable asynchronous slices keyed by task ID, so a begin on one
thread can match an end on another without falsely occupying a single thread
for the entire wall duration. `--flows` adds wake-to-run arrows; omit it for a
less crowded timeline.
