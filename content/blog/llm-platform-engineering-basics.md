---
title: "LLM Inference Platform Engineering - Part 1 - Overview"
date: 2026-10-10T18:00:00+02:00
description: "The first part of my LLM Inference Platform Engineering series, providing a high-level overview of the basics."
tags: ["Kubernetes", "AI", "GPU", "LLM"]
draft: false
wideCode: true
---

LLM Inference Platform Engineering is an area that is becoming increasingly popular due to the widespread use of LLMs everywhere. If we think about it, it makes perfect sense: you are not writing code by hand anymore, are you? :)
However, the LLM you prompt to design a rocket ship and tell "should not make mistakes pls" needs to **run somewhere**. Today, 99% of the time, you don't care where; you just fire up Claude or the latest version of ChatGPT, which reads your prompt, waits a bit, and spits out the answer -- so you might ask: why would I even need to understand this?

The answer is simple: **this is not going to stay like this for long**. If you are working as part of an organization (mid-sized or big), you might have gone through the following stages (flawlessly communicated by your leadership, obviously):

1. **Stage 1:** LLMs are dangerous; we need to use them with caution!
2. **Stage 2:** LLMs are super capable; let's ship more features!
3. **Stage 3:** Our whole company is an AI-first company now. Use as many tokens as you can, put AI in every presentation you give, and do not even think about reviewing code written by an LLM -- use an LLM to review the code written by an LLM!
4. **Stage 4:** Well... this is costing us a lot of money (since Anthropic realized its monopoly situation, it started raising its prices like craaazy), so please use it carefully: only use higher-tier models if necessary, and use the dumber models for everything else.
5. **Stage 5:** f\*\*k me, this is really expensive; we are limiting everyone to X dollars per month (where X gets spent in a week)!
6. **Stage 6:** Couldn't we just host it ourselves using open-source models and "only pay for the infra" (because screw operational costs)?

Stage 6 might have to wait a bit for a few companies -- but I have a really strong hunch that this is going to be the case for most, and we want to be ready. This series is intended to cover my understanding of the current landscape and to solidify some of what I've learned. The thing that's hard about this in general is the fact that as platform engineers, we have to understand **so much stuff**, and now there's a whole new area we need to dig into. Remember how long it took us to be comfortable with K8s? Now your HTTPRoute setup for your Gateway API implementation is useless, your HPA scaling based on memory/CPU utilization can be thrown out of the window, you'll come across new K8s terminology like _LeaderWorkerSet_ and _DisaggregatedSet_, traditional service meshes won't help you, and all the metrics you thought were important won't matter that much anymore. TL;DR: a fun journey lies ahead!

### Why are **GPUs** all the rage now?

As far as raw resources are concerned, we've only had to deal with disk, CPU, and memory. Disk space has been a non-factor for a long time because SSDs and HDDs have become dirt cheap. Memory and CPU, on the other hand, have always been considered precious resources, so our focus has been on these two.
We know that computation happens on the CPU -- so why on earth can't we keep using it for inference workloads? Those require computation, just like the server running my awesome backend rewritten in Rust, right?

![CPU vs GPU architecture](/blog/images/llm-platform-engineering-overview/gpu-vs-cpu-blog.jpg)

Without going into too much unnecessary detail about the actual hardware architecture of CPUs and GPUs, the main thing to remember is that CPUs have a **few powerful cores** that are great at executing a smaller number of complex instructions (compared to the GPU) very quickly: application logic, web servers, databases, operating systems -- so operations that require a lot of branching and complexity. GPUs, on the other hand, have **thousands of smaller cores** that are great at executing simple arithmetic operations (a LOT of them) over and over again. Spoiler alert: LLMs require the latter.

Another issue is **bandwidth**: high-end server CPUs are capable of moving a _few hundred GB_ per second from RAM (DRAM → memory controller → CPU caches (L3/L2/L1) → registers/vector units → computation), whereas GPUs are capable of moving _multiple TB_ per second from their high-bandwidth memory units towards the computation cores (HBM → GPU cache/shared memory/registers → tensor cores → computation). **HBM** stands for High Bandwidth Memory, which is specifically designed for ultra-high bandwidth and low latency, and tensor cores are a type of GPU core specialized at the hardware level to perform billions of **matrix operations** faster than any "regular" cores.

LLMs need to execute a **huge number of matrix operations** because nearly every major step in a **transformer** (where these matrix calculations take place) is built from linear algebra (bleh). Each token is represented as a vector of numbers, and the LLM repeatedly multiplies these vectors by large weight matrices. Since this happens across many tokens, many layers, and billions of learned parameters, a single generated token can require an enormous number of multiply-and-accumulate operations. These operations are not complex, but they happen billions of times over and over, which makes GPUs much better suited to this work because of their architecture.

![High-level architecture of traditional LLMs](/blog/images/llm-platform-engineering-overview/llm-overview.png)

It is also worth mentioning that there are models that can be run on CPUs (for example, SmolLM) because their parameter counts are small enough that the amount of computation and memory movement stays manageable on a CPU. In general, **the number of parameters is strongly correlated with how much compute power is needed: more parameters mean more weights must be loaded and more multiply-accumulate operations must be performed for each token**, so larger models require much more memory bandwidth and processing throughput. SmolLM has a version that has only 135 million parameters, whereas something like Llama 3.1 405B has **405 billion parameters** -- good luck running that on your gaming CPU!
