# 3 AI Completion-Rate Engines + Max Memory Upgrade

## Overview
Implement all 3 state-of-the-art AI completion-rate improvements plus dramatically increase memory limits to match high-performance gaming/graphics app levels for iPhone 16e (8GB RAM) or better.

---

## Feature 1: AI Predictive Session Pre-Conditioning
Instead of the health monitor just blocking risky sessions, it now **pre-optimizes every session** before launch using all historical data for that host.

- Analyzes which network config, fingerprint profile, URL variant, timing window, and pattern strategy historically yielded the highest completion rates for each host
- Pre-configures the session with the optimal stack (best proxy type, best stealth profile, best URL, best pattern order, best timing profile)
- Queries the AI to generate a "pre-conditioning recipe" when enough data exists (10+ attempts on a host)
- Persists optimal configs per-host so the system gets smarter over time
- Falls back to sensible defaults for new/unknown hosts
- Integrates directly into the login automation engine — sessions launch pre-optimized instead of using generic defaults

## Feature 2: AI Multi-Signal Outcome Rescue Engine
When a session ends as `unsure`, `timeout`, or low-confidence, the AI performs a **deep cross-reference rescue** instead of throwing the result away.

- Captures a comprehensive signal bundle at session end: page content, current URL, redirect chain, cookie changes, page title, screenshot OCR text, timing fingerprint, HTTP status
- Cross-references all signals against historical pattern matches for that host
- Sends the full signal bundle to AI for deep analysis when confidence is below 60% (up from current 45%)
- Can rescue `timeout` outcomes (currently never re-evaluated) by analyzing whatever page state existed at timeout
- Can rescue `connectionFailure` outcomes where the page partially loaded
- Tracks rescue success rate and auto-calibrates the rescue threshold
- Persists rescued outcomes and feeds them back into the learning systems

## Feature 3: AI Reinforcement Interaction Graph
A per-site reinforcement learning system that maps **exact action sequences** to success/failure outcomes and converges on optimal interaction recipes.

- Builds an "interaction graph" per host: records the full sequence of actions (wait durations, input methods, scroll positions, click strategies, dismiss sequences, timing between actions)
- Each action in the sequence gets a reward signal based on whether it contributed to a successful completion
- After ~10 attempts on a site, the system converges on a near-perfect interaction recipe
- Recommends specific action sequences for each cycle (e.g. "use TRUE DETECTION, wait 2.3s, fill email with calibrated typing, pause 450ms, fill password, hover 200ms, click")
- Decays old data so the graph adapts to site changes
- AI periodically analyzes the graph to identify bottleneck actions and suggest optimizations
- Integrates with the pattern selection logic — replaces random fallback with data-driven sequence selection

## Memory Upgrade
Dramatically increase all memory thresholds to match what a high-performance gaming/graphics app would use on iPhone 16e (8GB RAM) or better.

- **Default WebView memory limit**: 1024MB → **2048MB** (2GB)
- **Max WebView memory limit slider**: 1024MB → **6144MB** (6GB)
- **Crash Protection soft threshold**: 250MB → **1500MB**
- **Crash Protection high threshold**: 350MB → **2500MB**
- **Crash Protection critical threshold**: 450MB → **4000MB**
- **Crash Protection emergency threshold**: 550MB → **5000MB**
- **Memory stepper step size**: 64MB → **256MB** (for the larger range)
- Screenshot cache and other memory-sensitive services scale their limits proportionally
