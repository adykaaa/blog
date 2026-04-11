---
title: "[EXAMPLE] [AI GENERATED] Go Concurrency Patterns I Keep Coming Back To"
date: 2025-01-22
description: "Goroutines and channels are easy to learn and easy to misuse. A few patterns I reach for repeatedly in production Go code."
tags: ["go", "concurrency", "backend"]
draft: false
---

Go's concurrency model is genuinely one of my favorite things about the language. Goroutines are cheap, channels are expressive, and the `go` keyword makes parallelism feel almost too easy.

That "almost" is doing a lot of work. Here are the patterns I reach for repeatedly, and the failure modes I've learned to avoid.

## Worker pools

The canonical use case: you have N items to process and want to parallelize across M workers without spawning N goroutines.

```go
func processItems(items []Item, workers int) []Result {
    jobs := make(chan Item, len(items))
    results := make(chan Result, len(items))

    // Start workers
    var wg sync.WaitGroup
    for i := 0; i < workers; i++ {
        wg.Add(1)
        go func() {
            defer wg.Done()
            for item := range jobs {
                results <- process(item)
            }
        }()
    }

    // Send jobs
    for _, item := range items {
        jobs <- item
    }
    close(jobs)

    // Wait and close results
    go func() {
        wg.Wait()
        close(results)
    }()

    var out []Result
    for r := range results {
        out = append(out, r)
    }
    return out
}
```

Key details: close `jobs` to signal workers to stop. Use a separate goroutine to close `results` after the WaitGroup drains, so the consumer loop terminates.

## Context for cancellation

Never start a long-running goroutine without a way to stop it. `context.Context` is the idiomatic mechanism.

```go
func pollForUpdates(ctx context.Context, interval time.Duration) {
    ticker := time.NewTicker(interval)
    defer ticker.Stop()
    for {
        select {
        case <-ticker.C:
            fetchUpdates()
        case <-ctx.Done():
            return
        }
    }
}
```

The `select` on `ctx.Done()` means this goroutine terminates cleanly when the caller cancels. This is the pattern. Always pass context, always select on `Done()`.

## errgroup for parallel tasks

When you need to fan out N parallel operations and collect errors, `golang.org/x/sync/errgroup` saves a lot of boilerplate.

```go
func fetchAll(ctx context.Context, urls []string) ([][]byte, error) {
    g, ctx := errgroup.WithContext(ctx)
    results := make([][]byte, len(urls))

    for i, url := range urls {
        i, url := i, url // capture loop variables
        g.Go(func() error {
            body, err := fetch(ctx, url)
            if err != nil {
                return fmt.Errorf("fetch %s: %w", url, err)
            }
            results[i] = body
            return nil
        })
    }

    if err := g.Wait(); err != nil {
        return nil, err
    }
    return results, nil
}
```

`g.Wait()` returns the first non-nil error. The context derived from `errgroup.WithContext` is cancelled on the first error, so other goroutines see cancellation and return early.

Note the `i, url := i, url` capture — this is still required in Go versions before 1.22 where loop variables were shared.

## The leak detector mindset

Goroutine leaks are insidious. They don't crash; they just slowly consume memory and CPU until something else fails.

Every time I start a goroutine, I ask: _what causes this to stop?_

- Is it range over a channel? Make sure the channel is closed.
- Is it a select loop? Make sure one case leads to `return`.
- Is it waiting on a mutex or channel? Make sure the other side always progresses.

`goleak` (uber-go/goleak) is excellent for catching leaks in tests:

```go
func TestSomething(t *testing.T) {
    defer goleak.VerifyNone(t)
    // ... test code
}
```

It compares goroutine stacks before and after the test. If any goroutines leaked from your test, it tells you where they were created.

## Closing thought

Channels are communication; mutexes are coordination. Use channels when goroutines are passing ownership of data. Use mutexes when goroutines are sharing state they both need to read and write. Mixing them without clear ownership semantics is where most concurrent Go bugs live.

When in doubt, reach for `sync.Mutex` before channels. It's less elegant but harder to get wrong.
