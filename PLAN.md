# Fix All Build Warnings (Concurrency & Minor Issues)


## Summary

Fix all compiler warnings from the device build — these are concurrency safety warnings and one minor code quality issue.

### Fixes

1. **SuperTestService.swift** — The `testProxy` method is marked `nonisolated` but references `self.logger` inside a `Task { @MainActor in }` block. Since `self` is captured in a `nonisolated` context, the `lastErr` var reference triggers a warning. Fix: remove the logging Task entirely (it's in a nonisolated context and can't safely access `self.logger`), or capture all needed values before the Task.

2. **TrueDetectionService.swift** — `TrueDetectionConfig` default initializer `.init()` is being called from a context the compiler considers nonisolated. Fix: ensure the default parameter value for `config` doesn't cross isolation boundaries.

3. **VisionMLService.swift** — `var enrichedInstances` is never mutated. Fix: change to `let`.

4. **VPNProtocolTestService.swift** — Multiple issues:
   - Class marked `nonisolated final class: Sendable` but the compiler still warns about `Sendable` conformance — fix: add `@unchecked Sendable` 
   - `ContinuationGuard()` init and `.tryConsume()` calls inside NWConnection callbacks (DispatchQueue closures) trigger isolation warnings — these are already `nonisolated` in the current code but the callbacks cross isolation. Fix: ensure `ContinuationGuard` usage is fully compatible with the nonisolated context.

### No visual or behavioral changes — only compiler warning suppression.
