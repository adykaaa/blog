---
title: "[EXAMPLE] [AI GENERATED] Caching at Scale: Patterns, Pitfalls, and When Not to Cache"
date: 2025-02-10
description: "Caching is one of the most powerful tools in distributed systems design and one of the easiest to misuse. A practical look at cache strategies, invalidation, and the cases where you're better off without one."
tags: ["system design", "caching", "distributed systems"]
draft: false
---

There are only two hard things in computer science: cache invalidation, naming things, and off-by-one errors.

The joke is old but the pain is evergreen. Caching is one of the most effective performance levers available, and one of the most reliably misused. Let's talk through the practical landscape.

## Why cache at all?

The motivation is simple: compute and I/O take time. If you've already done a computation, or fetched a value from a database, and the answer hasn't changed, why do it again?

The tradeoff is consistency. A cache is, by definition, a stale copy of the truth. Every caching strategy is an answer to the question: _how stale can I afford to be, and for how long?_

## Cache-aside (lazy loading)

The most common pattern. The application code checks the cache first; on a miss, it fetches from the source of truth, writes to the cache, and returns the result.

```go
func getUser(id string) (*User, error) {
    if cached, ok := cache.Get(id); ok {
        return cached.(*User), nil
    }
    user, err := db.GetUser(id)
    if err != nil {
        return nil, err
    }
    cache.Set(id, user, 5*time.Minute)
    return user, nil
}
```

**Pros:** Only caches what's actually requested. Cache failures degrade gracefully — the app still works, just slower.

**Cons:** Cold starts are slow. A cache miss under high load causes a **thundering herd**: every request hits the database simultaneously. Mitigate with locks or probabilistic early expiration.

## Write-through

On every write, update the cache and the database together. Reads always hit the cache; writes hit both.

**Pros:** Cache is always warm. No read-time misses after a write.

**Cons:** Every write pays double. You end up caching data that's rarely read. Works well when read-to-write ratio is high.

## Write-behind (write-back)

Write to the cache synchronously, write to the database asynchronously. Higher write throughput at the cost of durability.

This is how most database buffer pools work. It's also how you lose data if your cache layer goes down before the async flush completes. Use with care and explicit trade-off acknowledgment.

## TTL is not invalidation

Setting a TTL of five minutes doesn't mean your cache is consistent within five minutes. It means it's _eventually_ consistent with a five-minute bound — in the happy path, with no failures.

Real invalidation requires either:

1. **Event-driven purges** — when the source changes, send a signal to invalidate the cache entry. Works well but creates coupling and adds a failure mode.
2. **Versioned keys** — include a version or timestamp in the cache key. Old keys are never invalidated; they just get evicted when the TTL expires. No invalidation logic, but can cause key explosion.

Neither is perfect. Choose based on your consistency requirements.

## When not to cache

Not everything benefits from caching.

- **Highly personalized data** — per-user results that vary constantly. Cache hit rates will be low; the overhead may exceed the benefit.
- **Data that changes faster than your TTL** — you're serving stale data with false confidence.
- **Write-heavy workloads** — constant invalidation negates the read benefit.
- **When you haven't measured** — caching is an optimization. Optimize for the bottleneck you've observed, not the one you've assumed.

Profile first. The L1 cache on your CPU is already doing a lot of work.

## The metrics that matter

When you add a cache, track:

- **Hit rate** — below 80% is usually a signal something is wrong
- **Eviction rate** — high evictions mean your cache is undersized for the working set
- **Miss latency** — the tail latency on misses dominates overall p99 when hit rates dip

Treat your cache like any other service: SLOs, alerts, dashboards. A cache that goes down silently is worse than no cache.

---

Caching is powerful, humble, and underspecified in most architecture discussions. The next time someone proposes adding a Redis layer, the first question should be: what are we measuring, and how will we know if it helped?
