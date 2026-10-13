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
| `io` | Completion submit and terminal outcome |
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

`task_begin` and `task_end` delimit task execution, including direct switches and
inline blocking work. An end carries only its reason and closes the latest begin
on that thread. Reasons distinguish runnable yield, waiting, and completion.
Inline blocking work pauses its parent's trace interval and uses a separate task
ID. The parent resumes after the blocking scope returns, including after
suspension or migration.

Main-task execution is separate from scheduler work. Worker executors do not
execute their synthetic main task. Nonzero task IDs are session-unique and stay
unchanged during migration. Threads reserve blocks of 1,024 IDs from a global
counter, then assign locally. Ordinary IDs need only one to three varint bytes.
Creation carries parent/group identity. Wakes identify the emitting thread.
If creator-thread registration fails, a task still gets a unique ID. The trace
counts the missing creation record as loss instead of stopping the workload.

A thread starts a new recorded lifetime when its runtime role or executor
identity changes. Each lifetime uses a distinct thread index, even when the OS
thread ID stays the same. Other-thread markers do not change an executor or
worker role.

Park events enclose executor idle handling. Poll events enclose only backend
polls, not callback dispatch: timeout zero means a nonblocking check; the maximum
u64 represents an unbounded wait. Loop wake events mean a backend wake was
actually issued. Completion addresses identify I/O submissions and terminal outcomes.
Addresses may be reused after a terminal outcome. I/O events use the emitting
thread's buffer, even when another thread owns the loop. A timer disarm records
one canceled outcome. Resetting a running timer does not create another submission.
Executor shutdown records cancellation for internal operations that remain armed.
These records do not invoke callbacks or change completion state.

Blocking work records distinguish queue submission and execution. User zones
are nested begin/end events with a source-location definition preceding first
use on each thread. Plots use signed 64-bit values.

## Function attribution

Native spawn wrappers record the user function address and skip stack capture.
Only unknown user functions (such as generic `std.Io` async/concurrent/group
wrappers) get a bounded spawn-side stack and a first-suspension frame-pointer
stack. Main tasks need neither. Stack
attribution in release builds requires frame pointers on both the executable
and zio modules: set `.omit_frame_pointer = false` in their module options (or
assign `exe.root_module.omit_frame_pointer = false` and
`zio_module.omit_frame_pointer = false` in the build script). Keep DWARF for
source lines and inline contexts. The analyzer can recover an enclosing user
function from a captured PC's inline metadata. Optimization can still remove
frames or useful debug information.

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
bit test; active encoding and stack capture are out-of-line. Executor and
loop-state hooks use cached thread pointers. I/O and other-thread hooks use a
generation-checked TLS cache to retain producer ownership. Slice-free events
encode in one pass with a compile-time size bound. Strings and stacks use an
exact-length check.
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
Use `-h` or `--help` after any command to show help without loading a session.

`info` reports the clock fit, observed duration, threads, dropped events, and
recording diagnostics. A final end record confirms the total dropped count.
Without it, the reported count is a lower bound. Reports, SVGs, and Perfetto
exports show this distinction and warn about recording loss or damage.

Files ending mid-record retain earlier complete records. The analyzer skips
files with a different process, session timestamp, clock, or nominal frequency.
It counts these header mismatches. Missing thread metadata does not discard
events. The analyzer labels the thread unknown and does not estimate its utilization.
Diagnostics also count incomplete slices, task/I/O pairing errors, and pending I/O.

Unknown record kinds are skipped. An unknown event ends only its chunk.
Chunks are reordered by sequence number before event decoding. Nanoseconds
come from a least-squares calibration fit, or one calibration point and the
nominal clock frequency.

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
blocking workers use work / observed wall time. Nested jobs count their
combined occupied interval once. The rest of the lifetime counts as idle,
apart from trace-flush overhead. Inline work does not occupy a physical
blocking worker. `thread_begin` and `thread_end`
bound each thread's observed lifetime, including idle time before its first job
and after its last. If lifecycle markers are missing, first/last events provide
fallback bounds; either missing boundary falls back independently. Other threads display
point events rather than a utilization estimate. The row background and binned
activity are clipped to the observed interval; time outside it is blank.
Bins may average very short activity bursts.

`stats` groups task slices by resolved function name and reports run time,
wake-to-run latency, and completed-task lifetime. It also reports per-thread
states, I/O submit-to-terminal latency, blocking queue/wall time, steals, parks,
zones, and plot summaries. I/O distributions separate completed, failed, and
canceled/disarmed outcomes by operation. Pending and unmatched I/O does not
enter a latency distribution. Blocking wall duration includes suspension and
OS waits. It is not CPU time, including for physical blocking workers.
Durations use microseconds except the labeled thread-state table.
Percentiles use the nearest rank. Unfinished task lifetimes are not latency samples.

Text reports escape control characters and invalid UTF-8 bytes in labels.
Printable Unicode remains readable.

Source-location definitions apply process-wide. Zone stacks follow tasks across
thread migration; markers outside a running task use the emitting thread's
stack. Zone wall duration includes suspension time. Task-zone running duration
sums the task's running time within the zone. Thread-only zones have no task
running sample. Zone statistics aggregate by source location across all threads.
Task-running time excludes coroutine suspension but includes OS waits and
preemption. It is not physical CPU time.

Task naming prefers an explicit user function, then the first non-runtime
suspension-stack frame, then a spawn caller rendered as `spawned at file:line`,
then the entry symbol, and finally a hexadecimal address. Executor main tasks
are labelled `main (executor N)`. Runtime-frame filtering is heuristic: it skips
`std`/`zio` namespaces, Zig `lib/std/`, and zio `src/` paths (including relative
`src/` paths). The analyzer checks enclosing DWARF inline contexts before it
discards a physical frame as runtime code. Declaration files help runtime
filtering but never replace missing call-site coordinates. Unusual source
layouts or optimization can weaken attribution. Missing symbols do not prevent
timeline or utilization analysis.

Open `trace.json` in [Perfetto](https://ui.perfetto.dev/) or
`chrome://tracing`. The export retains the recorded process ID and executable name.
Each thread has separate lanes for execution, states, parks, physical work, and
wake points when present. Display thread IDs identify these derived lanes,
not OS threads. Track metadata retains the trace thread index and lane name.
Known thread labels include the OS thread ID and executor.

Task zones and inline blocking work use process-local asynchronous slices.
Their IDs include the capture timestamp. Endpoints can cross threads without
falsely occupying one physical thread for the full wall duration.
Physical blocking work stays on its worker's work lane.

`--flows` adds wake-to-run arrows with capture-scoped numeric bindings.
Their endpoints are zero-duration slices at the recorded wake and run timestamps.
Omit flows for a less crowded timeline.

The Perfetto JSON includes `zioTrace.sessionPath`, `zioTrace.recordedClasses`,
and `zioTrace.diagnostics`. SVG metadata also includes recording diagnostics.
Visible warnings flag incomplete or damaged recordings in both formats.
Unclassified intervals retain explicit labels. Absent classes do not imply zero activity.
