# Prefill

In the previous section we followed a single token (`bank`) as it built up its context-dependent representation using Q, K, V, and O. Now let’s zoom back out, because the model obviously doesn’t get your prompt one token at a time – it gets the whole thing at once.

When you hit enter, the LLM does two very different kinds of work. First, it has to read and understand your entire prompt. Only then can it start writing the answer, one token at a time. The first phase is called **prefill**, the second one is called **decode**.

This section is about the first one, and (spoiler alert) the two behave so differently on a GPU that a big chunk of LLM platform engineering is about scheduling them without letting one wreck the latency of the other.

## What prefill actually does

Back to our favourite prompt:

> Take me to the nearest OTP bank.

All 8 tokens already exist when the request arrives at the model. Causal attention still means each position can only see itself and earlier positions, but unlike generated tokens, we don’t have to wait for those earlier tokens to be produced – they are already there.

That means the GPU can process the prompt positions in parallel.

Conceptually, prefill pushes the whole prompt through all layers in one forward pass. In every attention layer, Q, K, and V are calculated for all 8 tokens, every token’s Query is compared against the Keys of the tokens it is allowed to see (causal self-attention and all that jazz), Values get mixed, `o_proj` does its thing, and the result moves on to the next layer.

Serving engines may split a very large prefill into smaller chunks for scheduling reasons, but that is an optimization we’ll get to later. The important mental model for now is: **the prompt is already known, so its positions can be processed in parallel instead of autoregressively.**

At the end of the last layer comes the black box we agreed not to care about (LM Head, logits, token selection), and out pops the first generated token:

```text
prompt tokens: [Take, me, to, the, nearest, OTP, bank, .]
      ↓ embedding lookup for all 8 tokens
      ↓ layer 0: Q, K, V for all 8 tokens -> attention -> O -> feed-forward stuff -> next layer
      ↓ layer 1: same thing
      ↓ ...
      ↓ layer N: same thing
      ↓ LM Head -> logits -> pick a token
first generated token: "Sure"
```

Two things are worth noticing here.

**Prefill is many tokens in, one generated token out.** It does not matter whether your prompt is 8 tokens or 80,000 tokens: from the user’s perspective, prefill culminates in the first generated token. The rest of “Sure thing boss, the nearest OTP bank is…” is produced later, during decode.

**Prefill leaves useful state behind.** As a side effect of calculating attention for the prompt, the model has now computed the K and V vectors for every prompt token, in every layer – exactly the stuff the next generated token will need.

Notice I said **K and V**, not Q and O.

Hold that thought until the next section.

## Why prefill is “compute-bound”

Remember the GPU section, where I said there are operations where compute is king and others where capacity + bandwidth matter more?

Prefill is usually the compute-is-king one.

During prefill, the model does not multiply one token vector with `q_proj.weight`, then fetch the same giant weight matrix again for the next token, then again for the next one.

Instead, it stacks many token vectors into a matrix (roughly shaped like `[number of tokens, hidden dimension]`) and performs large matrix multiplications against the model weights.

The important bit is that weight data brought in from HBM can be reused across many token rows while the GPU performs a lot of math.

That means a lot of computation happens for every byte moved from memory.

There is a name for that ratio: **arithmetic intensity**.

High arithmetic intensity is where GPUs shine. Thousands of cores stay busy doing useful math, and raw memory bandwidth is less likely to be the thing holding you back.

This is exactly the kind of workload GPUs were built for.

Some napkin-scale intuition: a dense 70B model implies tens of billions of weight operations per token. Run a 1,000-token prompt through it and you are suddenly talking about tens of trillions of operations before we even account for all of the attention work.

Modern datacenter GPUs can chew through an absurd amount of math, so this can still happen quickly. But the important point is that prefill is not some cheap setup step. A long prompt is a serious compute workload.

And attention has a nastier scaling property.

The big projection and feed-forward operations grow roughly linearly with prompt length: twice the tokens, roughly twice the work.

Attention is different.

Every token compares its Query against the Keys of the tokens before it, so the amount of attention work grows roughly quadratically with sequence length.

Double the prompt and that part of the work grows by about 4×.

Long prompts do not just cost more. At some point, parts of the computation start costing **disproportionately** more.

## Why you, as a platform engineer, care

This is the part where all of the above stops being theory.

### Time To First Token (TTFT)

Prefill sits directly on the critical path before the first output token can appear.

It is not literally the whole TTFT. Your request may also spend time being tokenized, sitting in a queue, waiting for the scheduler, moving across the network, or going through sampling and other runtime overhead.

But once execution reaches the model, prefill is usually one of the biggest contributors – especially for long, uncached prompts.

So TTFT becomes an end-to-end platform SLO:

```text
request
  ↓
tokenization / request processing
  ↓
queueing + scheduling
  ↓
prefill
  ↓
first generated token
```

If TTFT is bad, the user does not care that your decode is blazing fast. They are still staring at a blinking cursor.

### Prompt length is your load

Your users’ 8-word question is not what the model sees.

Add the system prompt, chat template tokens, 12 RAG chunks someone glued onto it, the previous 40 turns of conversation, tool definitions, and the agent that dumps every tool output back into the context, and that “8-token” prompt is suddenly 20,000 tokens.

The cost of prefill is determined by what actually ends up in the context, not by what the user typed into the box.

That makes prompt construction a platform concern.

A change in the application layer – larger RAG chunks, more chat history, a verbose system prompt – can show up as higher GPU utilization and worse TTFT even if request rate has not changed at all.

### One monster prompt can hurt everyone

A GPU chewing through a 100k-token prefill is spending a lot of time doing compute-heavy work.

Meanwhile, other requests may already be in decode, waiting for their next token.

This is where scheduling gets interesting.

Inference engines have tricks for avoiding a huge prefill from monopolizing the GPU. vLLM, for example, supports **chunked prefill**: break a large prompt into smaller pieces and interleave that work with decode requests.

Conceptually:

```text
without chunking:

[------------- giant prefill -------------][decode][decode][decode]

with chunking:

[prefill chunk][decode][prefill chunk][decode][prefill chunk][decode]
```

We’ll come back to the exact scheduling mechanics later. For now, the point is simple:

**one oversized prompt can become a noisy neighbour.**

### Prefill and decode stress the GPU differently

Prefill tends to be compute-bound.

Decode, as we’ll see next, tends to be memory-bandwidth-bound.

That does **not** mean running them on the same GPU is inherently wrong. In fact, a good scheduler can sometimes mix compute-heavy prefill work with bandwidth-heavy decode work efficiently.

The problem is that when both phases share the same GPU fleet, they also share the same scheduling decisions, parallelism strategy, capacity, and failure domain.

At enough scale, you may want to tune them independently.

That is the idea behind **disaggregated serving**: run prefill workers and decode workers separately so you can provision and optimize each phase around the thing it actually cares about.

Prefill workers can be optimized for TTFT and compute throughput.

Decode workers can be optimized for inter-token latency and memory bandwidth.

And this is what that scary `DisaggregatedSet` from the intro is ultimately about.

Teaser for a later part.

## Takeaway

Prefill is the phase where the model processes the already-known prompt positions in parallel and produces the first generated token.

While doing that, it calculates Q, K, and V for every prompt token in every layer. The K and V vectors are especially important because they are the reusable state future generated tokens will need.

Prefill tends to have high arithmetic intensity, which makes it largely compute-bound. Its cost grows with prompt length, and the attention part grows roughly quadratically.

From a platform engineer’s point of view, this shows up as **TTFT**, GPU contention, scheduling pressure, and noisy-neighbour problems caused by very large prompts.

At scale, the fact that prefill and decode stress the GPU differently even becomes an architectural question: schedule them together carefully, or split them apart and optimize them independently.

Either way, we are now holding the K and V vectors of every prompt token.

It would be a shame to throw them away.

Which brings us to the **KV Cache**.
