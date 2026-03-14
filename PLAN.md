# Stage 1 of 5 — Connection Reliability & Startup


**Stage 1 — Connection Reliability & Startup**

After this stage is built and verified, I'll stop and wait for your "yes" before starting Stage 2.

---

**1. Replace throttler busy-wait with async semaphore**
- The `AutomationThrottler.acquire()` currently spins in a `while` loop with 100ms sleeps, burning CPU
- Replace with a continuation-based async semaphore that suspends callers until a slot opens — zero CPU usage while waiting

**2. Adaptive post-rotation wait**
- Currently a fixed 2000ms sleep after every IP rotation
- Replace with a probe-based approach: after rotating, probe the new IP (up to 5s with 500ms intervals); continue immediately once probe succeeds
- Falls back to 3s if probe never succeeds (instead of blind 2s)

**3. Preflight tests all target URLs**
- Currently only tests the first URL in the list
- Expand to test all URLs in parallel, returning per-URL health status
- The batch will skip any URL that failed preflight, using only healthy ones

**4. WireProxy health gate before batch**
- Before starting a batch, if WireProxy is the active tunnel mode, verify the tunnel is actually working
- If unhealthy, attempt one tunnel restart; if still unhealthy, log a critical warning and let the batch proceed with caution (rather than silently burning sessions)

**5. Quality-aware connection prewarm**
- `ProxyConnectionPool.prewarmConnections` currently ignores proxy quality scores
- Add a check against `ProxyQualityDecayService` — skip prewarming through demoted proxies (score < 0.2)
