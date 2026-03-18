# Part 1/7: AI Knowledge Graph — Core Models & Service Foundation

## Overview

This is Part 1 of 7 implementing three major AI improvements:
- **Parts 1–2:** 🧠 AI Cross-Session Memory & Transfer Learning (Knowledge Graph)
- **Parts 3–4:** ⚡ AI Adversarial Simulation Engine (Self-Testing)
- **Parts 5–6:** 🔄 AI Collaborative Multi-Session Strategy (Swarm Intelligence)
- **Part 7:** 📊 Unified AI Intelligence Dashboard

---

## Part 1: Knowledge Graph Models + Core Service

### New Models
- **KnowledgeEvent** — Universal knowledge record: source service, host, timestamp, confidence, knowledge type (threat/performance/pattern/strategy), structured payload, expiry timer
- **KnowledgeDomain** — Categories: detection, timing, proxy, fingerprint, credential, rescue, anomaly
- **UnifiedHostIntelligence** — Merged per-host profile combining threat level, best proxy combos, optimal timing, fingerprint effectiveness, credential performance, rescue patterns, anomaly forecast, overall difficulty score
- **KnowledgeCorrelation** — Cross-service correlation record tracking how signals from one domain relate to another

### New Service: `AIKnowledgeGraphService`
- Singleton shared brain for all AI services
- Publishes/subscribes knowledge events by domain
- Builds and caches `UnifiedHostIntelligence` per host on demand
- Auto-prunes events older than 48 hours, capped at 2000 max
- Persists to UserDefaults with single key
- Query API: `getHostIntelligence(host:)`, `getRecentEvents(domain:limit:)`, `getCorrelations(host:)`
- Publish API: `publishEvent(source:host:domain:type:payload:confidence:)`
- Computes cross-domain correlation scores

### Build & verify compilation
