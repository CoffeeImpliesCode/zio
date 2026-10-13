# Runtime instrumentation

Build with `zig build examples -Dinstrument=true`. The default is `false`: hooks and
per-task trace data are compile-time eliminated. A root module can also set
`pub const zio_options: zio.Options = .{ .instrument = true };`.

Tracing starts when the first runtime is initialized. `ZIO_PROFILE=1` records all
event classes; `ZIO_PROFILE=sched,loop` records only selected classes. Unset,
empty, or a list without valid classes stays inactive: no files, writer, or
buffers are created. Unknown names produce a warning and are ignored. The last
runtime's `deinit` drains the writer and closes the session. Join external threads
that use instrumentation before deinitializing the last runtime.

```sh
zig build examples -Dexample=trace-demo -Dinstrument=true
ZIO_PROFILE=1 ./zig-out/bin/trace-demo
ZIO_PROFILE=sched,loop ./zig-out/bin/trace-demo
```

## Event classes

Use comma-separated names (surrounding whitespace is ignored):

| Class | Records |
| --- | --- |
| `sched` | Task lifecycle/functions, executor identity, parks and steals |
| `loop` | Backend polls and loop wake syscalls |
| `io` | Completion submit/complete |
| `work` | Blocking work queue/begin/end |
| `stacks` | Unknown-function spawn and first-suspend stacks |
| `user` | Source locations, zones, messages and plots |

Thread lifetime, flush, dropped-event and process records are always present in
an active session. The process record stores the selected mask, so omitted
categories mean **not recorded**, not zero activity. Stacks are captured only
when `stacks` is selected and the user function is unknown. With stacks disabled,
generic `std.Io` tasks can retain wrapper names; native function addresses still
provide attribution when `sched` is selected. A marker-only or stacks-only
session has no scheduler intervals for correlating task migration.

## Output layout

The working directory receives `.zio/<realtime_nanoseconds>/process.dump` and
`<os_thread_id>-<session_thread_index>.dump` for each event-producing thread. A
collision appends `-<pid>` to the directory name. Directory permissions are 0700;
files are 0600. Trace messages, paths, and user labels can contain private data.
The trace-local index prevents OS thread-id reuse from merging threads.

The process file records the executable path, runtime address of
`zio_trace_anchor`, selected classes, operation names, clock calibration, and final dropped count.
Thread files record thread kind, executor identity, and independently decodable,
consecutively numbered chunks. Executors and blocking-pool workers flush on exit;
other threads flush at session end. File I/O is raw OS I/O, never zio I/O.

## Events and protocol

`src/instrument/format.zig` defines version 2 of the binary protocol and provides
`FileReader`, `parseChunk`, and `EventIterator`. Version 1 is not accepted by the
v2 reader. Files start with a 40-byte `ZIOTRACE` header. Records carry a kind byte,
varint payload length, and payload. Chunks carry thread index, sequence number,
base timestamp, then events with a kind byte and timestamp delta. Unsigned
integers use unsigned LEB128; signed values use zigzag.
Strings are length-prefixed bytes, not NUL-terminated. Unknown records can be
skipped; unknown events terminate decoding of their chunk. A crash can leave a
truncated final record; earlier complete records remain readable.

`task_begin` and `task_end` delimit actual coroutine execution, including direct
coroutine-to-coroutine switches. In v2, an end carries only its reason and closes
the latest begin on that thread. Reasons distinguish runnable yield, waiting,
and completion. Main-task execution is separate from scheduler work; worker
executors do not execute their synthetic main task. Nonzero task ids are
session-unique and remain unchanged during migration. Threads reserve blocks of
1,024 ids from a global counter, then assign locally; ordinary ids need only
one to three varint bytes. Creation carries parent/group identity; wakes identify
the emitting thread.

Park events enclose executor idle handling. Poll events enclose only backend
polls, not callback dispatch: timeout zero means a nonblocking check; the maximum
u64 represents an unbounded wait. Loop wake events mean a backend wake was
actually issued. Completion addresses identify I/O submissions and finishes;
addresses may be reused after completion. Blocking work records distinguish queue
submission and worker execution. User zones are nested begin/end events with a
source-location definition preceding first use on each thread. Plots use signed
64-bit values.

## Function attribution

Native spawn wrappers record the user function address and skip stack capture.
Only unknown user functions (such as generic `std.Io` async/concurrent/group
wrappers) get a bounded spawn-side stack and a first-suspension frame-pointer
stack. Main tasks need neither. Stack
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
background writer. Public event hooks inline one monotonic class-mask load and
bit test; active encoding and stack capture are out-of-line. Executor/loop hooks
use cached thread pointers, avoiding TLS and generation lookup. Other-thread
hooks use a generation-checked TLS cache. Slice-free events encode in one pass,
using a compile-time size bound; strings/stacks use an exact-length check.
Most events need no lock. ID-block reservation and rollover use atomic handoffs.
The writer blocks on a futex until a chunk or shutdown notification, with a
calibration timeout of about one second.
Producers wait on their own buffer's futex if the spare is still in use; those
waits have flush brackets. Registration, source definitions, stack capture, and
lifecycle management are intentionally slower control paths. Thread-begin/end
events bound the observed lifetime, including idle blocking-worker time.
Calibration pairs ticks with monotonic time at start, approximately once a
second, and at end. Profiling writes real data and perturbs the measured program:
compare inactive and active ReleaseFast builds for the actual workload and disk.

The following x86_64 Linux ReleaseFast measurements used frame pointers and
`taskset -c 2,4` (two physical cores on one socket, one available for the writer).
The switch workload has two tasks each yielding 2,000,000 times on one executor;
the spawn workload creates 200,000 no-op tasks in groups of 100. Each step had
five interleaved runs per mode against preserved baseline binaries. Values are
medians in nanoseconds; CPU contention varied between rounds, so compare each
step with its contemporary baseline, not with another row.

| Cumulative change | Switch baseline / changed | Spawn baseline / changed |
| --- | ---: | ---: |
| Unknown-function-only stacks; v2 implicit task ends | 90.89 / 110.99 | 926.51 / 732.90 |
| Dense task-ID blocks | 132.33 / 105.55 | 882.09 / 668.10 |
| Executor/loop thread caches | 135.84 / 107.43 | 664.13 / 466.78 |
| Class-mask gates (final) | 133.35 / 111.80 | 925.20 / 691.08 |

The integrated comparison used seven interleaved runs per mode, with the same
workloads, compiler flags, and CPU affinity. No runs were excluded. Timed regions
exclude runtime setup and shutdown. Runs had large spreads on this shared host.
Dump sizes are median totals in decimal MB:

| Build / environment | ns/switch | ns/spawn | Switch dumps MB | Spawn dumps MB |
| --- | ---: | ---: | ---: | ---: |
| Preserved compiled-out baseline | 57.13 | 477.78 | — | — |
| Current compiled-out | 59.41 | 468.40 | — | — |
| Preserved tracing, profile unset | 51.36 | 466.95 | — | — |
| Current tracing, profile unset | 60.67 | 535.72 | — | — |
| Preserved tracing, profile `1` | 136.44 | 1025.81 | 63.24 | 17.47 |
| Current tracing, profile `1` | 115.10 | 698.04 | 26.19 | 8.67 |
| Current tracing, profile `sched,loop` | 118.12 | 721.89 | 26.12 | 8.69 |

Active switches improved 15.6% and spawns improved 32.0% against the preserved
tracing baseline. Inactive switches increased 9.31 ns and spawns increased
68.77 ns. Code generation no longer inlined `switchOut` into the yield loop.
A hook-local cold-branch hint did not restore inlining, so it was removed.
These changes are a measured trade-off, not a zero-overhead claim.

Strict decoding of retained benchmark recordings found no drops, sequence,
thread-lifetime, task-pairing, class-selection, or known-function stack errors.
The demo used 10,464 bytes with `sched,loop`, versus 14,441 bytes with all classes.
Thread interleavings also affect these sizes. With all classes, only the three
unknown-function tasks had spawn and first-suspend stacks.

### Varint experiment

LEB128 remains the wire codec. A prefix alternative used one unaligned eight-byte
store for the common form, with a nine-byte form above 56 bits. Short output
slices used a bounded copy. Neither codec needed extra buffer slack.

Seven interleaved ReleaseFast runs used `taskset -c 6,8`. The mixed v2 workload
contained 50% task begins, 30% task ends, 10% wakes, 5% I/O submissions, and 5%
16-frame stacks. The runtime comparison used frozen revision `7a97c388` with
v1 event layouts, not the integrated v2 runtime:

| Codec | Mixed encode ns/event | Mixed decode ns/event | Active ns/switch | Active ns/spawn |
| --- | ---: | ---: | ---: | ---: |
| LEB128 | 18.68 | 30.91 | 84.03 | 594.78 |
| Prefix | 20.56 | 19.31 | 113.36 | 667.67 |

Prefix reduced decode time but increased common-event encode time. The frozen
runtime runs were also slower. The rejected codec was removed.

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

The analyzer reads format v2 only; older format versions are rejected rather
than interpreted with the wrong event layout. Task ends carry no task ID: they
close the most recent task begin on that thread, including after a different
task has run there.

`info` lists the recorded event classes from the process record. Disabled classes
mean **not recorded**, not zero activity. If that record is missing, class
availability is unknown. Executor utilization requires both `sched` and `loop`
to separate scheduler work from blocking polls; blocking-worker utilization
requires `work` to distinguish jobs from idle time. Missing prerequisites produce
`n/a` with an explanation, and unclassified timeline time is shown as `unknown`.
Task statistics require `sched`; I/O and blocking statistics require `io` and
`work`; plots require `user`. Their sections say `not recorded` when disabled.
Without `stacks`, naming still uses explicit task functions, entry symbols, and
address fallbacks. Migration-safe zone pairing requires `sched` and `user`;
without task scheduling events, task ownership is unknown and zone statistics
are unavailable. Messages and plots remain usable when `user` alone is recorded.

`util` writes a self-contained, 1200-pixel-wide SVG and prints a thread table.
Executor rows split each bin into task, scheduler, nonblocking poll, blocking
poll, and tracing-flush time. Busy means task + scheduler + nonblocking poll;
blocking workers use work / observed wall time, with the rest of their lifetime
counted as idle (apart from trace-flush overhead). `thread_begin` and `thread_end`
bound each thread's observed lifetime, including idle time before its first job
and after its last. If lifecycle markers are missing, first/last events provide
fallback bounds; either missing boundary falls back independently. Other threads display
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

The Perfetto JSON also contains `zioTrace.recordedClasses` (or `null` for missing
process metadata) and a note about unavailable classes. Unclassified thread
intervals remain explicitly named; absent categories do not imply zero activity.
