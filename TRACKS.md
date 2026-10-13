# Work tracks of this fork

This fork (`CoffeeImpliesCode/zio`) carries two stacked tracks on top of upstream
`lalinsky/zio`. Both are jj bookmarks pushed to the fork.

| Track | Bookmark | Based on | Contents |
| --- | --- | --- | --- |
| fixes | `fixes` | `main` (upstream `main`) | Targeted fixes for upstream problems, one commit per fix, each fit for its own upstream PR. |
| zio-instrumented | `zio-instrumented` | `fixes` | Compile-time optional runtime tracing and the `zio-trace` analyzer (`docs/instrumentation.md`). |

This file lives on `zio-instrumented` only, so fix commits stay clean for upstream.

## Fixes

| Commit | Branch for a PR | Upstream | State |
| --- | --- | --- | --- |
| Make stack growth setup nest per thread | `fix-stack-growth-lifecycle` | [#811](https://github.com/lalinsky/zio/issues/811) | Implements the thread-local setup depth suggested in the issue. No PR yet. |
| Serialize stack growth handler install and removal | — | not reported | Found while reworking #811: the global handler refcount raced with installing and restoring the handlers. Stress test fails before the fix. |
| Join every blocking thread pool worker | — | not reported | Found by the instrumented test suite: workers leaving on the idle timeout, or on shutdown before `stop()` reached them, were never joined (stack leak; `stop()` could return with workers still exiting). Leak tests fail before the fix. |

Add a row per fix. When upstream merges a fix (or its own version of it), drop the
commit from `fixes` during the next rebase.

## Updating from upstream

```sh
jj git fetch --remote upstream
jj bookmark set main -r main@upstream
jj rebase -b fixes -d main                 # the fixes stack
jj rebase -b zio-instrumented -d fixes     # instrumentation on top
jj git push --remote origin -b main -b fixes -b fix-stack-growth-lifecycle -b zio-instrumented
```

Run the full suite on both tips after a rebase, and for `zio-instrumented` also with
`-Dinstrument=true` and `ZIO_PROFILE=1`.
