# Networking & Automation Improvements — 5 Stages

## Stage 1 — Connection Reliability & Startup ✅

- [x] Replace throttler busy-wait with async semaphore
- [x] Adaptive post-rotation wait (probe-based)
- [x] Preflight tests all target URLs in parallel
- [x] WireProxy health gate before batch
- [x] Quality-aware connection prewarm

## Stage 2 — Smarter Retry & Recovery ✅

- [x] Per-credential retry tracking in carry-over (max 3 retries per credential, exhausted → final .unsure)
- [x] AdaptiveRetryService learns from site behavior (tracks dominant failure patterns per host, adjusts delays/rotation)
- [x] Dynamic circuit breaker cooldowns (rate-limit 429 = 90s, timeout = 20s, 5xx = 45s, escalation on consecutive trips)
- [x] Batch-level exponential backoff on repeated all-fail batches (2s → 4s → 8s → 16s → 30s cap)
- [x] Active dead session detection with timeout watchdog (periodic heartbeat checks, early termination of hung sessions)

## Stage 3 — Proxy Intelligence ✅

- [x] Persist full success/failure history in ProxyQualityDecayService (survives restart)
- [x] Per-proxy bandwidth estimation in NetworkResilienceService
- [x] Quality-aware pool eviction (evict lowest-scoring idle connections first)
- [x] Raise weighted random selection floor (0.05 → 0.15 to reduce traffic to near-dead proxies)
- [x] Geographic latency routing (auto-select best region based on measured latency)

## Stage 4 — Batch Orchestration ✅

- [x] Real-time stats callback (every item or every 2, not every 5)
- [x] Batch-level timeout (global deadline across all sessions)
- [x] Adaptive inter-batch cooldown based on rate-limit signals
- [x] Credential priority queue (prioritize previously-inconclusive items)
- [x] Persistent auto-pause (re-triggers faster on sustained failures)

## Stage 5 — Network Resilience & Observability ✅

- [x] Replace Timer polling with NWPathMonitor in NetworkTruthService
- [x] Adaptive verification intervals (more frequent during batches, less when idle)
- [x] DNS failover strategy (multiple resolvers)
- [x] Connection multiplexing awareness (shared TLS sessions to same host)
- [x] Structured telemetry aggregation (metrics across batches, trend detection)
