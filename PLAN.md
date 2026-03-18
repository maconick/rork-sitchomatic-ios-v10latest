# Part 1: Batch Testing Crash Stability Fixes

## Problem

The app crashes instantly (no warning) during batch testing, especially with 4+ concurrent sessions. This is caused by:

1. **Unbounded WebView creation** — the batch task groups create WebViews faster than they can be released, exceeding memory limits
2. **Missing Task cancellation checks** — batch loops don't check for cancellation between iterations, so emergency stops can't halt runaway memory growth
3. **Checks array grows without limit** — every test inserts into `checks` at index 0, and the array is never capped during a batch, causing huge memory bloat on large batches
4. **No memory gate before spawning sessions** — new concurrent sessions launch even when memory is already critical
5. **Batch task captures `self` strongly** in `withTaskGroup` closures, preventing cleanup during emergency stops
6. **activeTestCount can drift** — if a task is cancelled mid-flight, the decrement never fires, blocking future batches

## What Changes (Part 1 — Batch Stability)

### Memory-Gated Session Spawning

- Before each new concurrent session starts, check current memory usage
- If memory is in the "high" or "critical" zone, pause spawning new sessions until memory drops
- If memory hits emergency level mid-batch, auto-stop the batch cleanly instead of letting the OS kill the app

### Bounded Checks Array

- Cap the `checks` array to 500 entries during batch runs
- Trim oldest completed checks when the cap is reached
- This prevents unbounded memory growth on large card/credential batches

### Cancellation Safety in Batch Loops

- Add `Task.isCancelled` checks at the top of every batch for-loop iteration
- Ensure emergency stop actually halts the task group promptly
- Add a timeout guard so no single batch can run indefinitely (safety net)

### WebView Acquire Safety

- Add a pre-acquire memory check in the WebView pool — refuse to create new WebViews if memory is critical
- Return existing pre-warmed views more aggressively under pressure
- Ensure every WebView release path fires even on task cancellation (using `defer`)

### activeTestCount Drift Protection

- Wrap the test execution + count decrement in a `defer` block so the count is always decremented, even on cancellation or crash
- Add a periodic reconciliation that syncs `activeTestCount` with actual non-terminal checks

### Screenshot/Debug Data Throttling During Batches

- Reduce screenshot retention to 20 during active batches (currently unlimited growth)
- Throttle debug log persistence to every 30s instead of 10s during high-concurrency runs
- Auto-purge debug screenshots when memory is above the soft threshold

### Applies to Both ViewModels

- All fixes apply to both `PPSRAutomationViewModel` (card testing) and `LoginViewModel` (credential testing)
- Both BPoint and PPSR gateway batch paths get the same protections

