---
title: "LLM Inference Platform Engineering - Part 1 - Overview"
date: 2026-10-10T18:00:00+02:00
description: "The first part of my LLM Inference Platform Engineering series, providing a high-level overview of the basics."
tags: ["Kubernetes", "AI", "GPU", "LLM"]
draft: false
wideCode: true
toc: true
---

LLM Inference Platform Engineering is an area that is becoming increasingly popular due to the widespread use of LLMs everywhere. If we think about it, it makes perfect sense: you are not writing code by hand anymore, are you? :)
However, the LLM you prompt to design a rocket ship and tell "should not make mistakes pls" needs to **run somewhere**. Today, 99% of the time, you don't care where; you just fire up Claude or the latest version of ChatGPT, which reads your prompt, waits a bit, and spits out the answer -- so you might ask: why would I even need to understand this?

The answer is simple: **this is not going to stay like this for long**. If you are working as part of an organization (mid-sized or big), you might have gone through the following stages (flawlessly communicated by your leadership, obviously):

1. **Stage 1:** LLMs are dangerous, we need to use them with caution!
2. **Stage 2:** LLMs are super capable, let's ship more features!
3. **Stage 3:** Our whole company is an AI-first company now (which is super unique because every other company is an AI first company now, these two letters are attracting VC money like blood attracts sharks).
4. **Stage 4:** We are counting how many tokens you are using and we'll make it part of your performance evaluation! (ffs...)
5. **Stage 5:** Well... this is costing us a lot of money (since Anthropic realized its monopoly situation, it started raising its prices like craaazy), so please use it carefully: only use higher-tier models if necessary, and use the dumber models for everything else.
6. **Stage 6:** f\*\*k me, this is really expensive; we are limiting everyone to X dollars per month (where X gets spent in a week)!
7. **Stage 7:** Couldn't we just host it ourselves using open-source models and "only pay for the infra" (because screw operational costs)?

Stage 7 might have to wait a bit for a few companies -- but I have a really strong hunch that this is going to be the case for most, and we want to be ready. This series is intended to cover my understanding of the current landscape and to solidify some of what I've learned. The thing that's hard about this in general is the fact that as platform engineers, we have to understand **so much stuff**, and now there's a whole new area we need to dig into. Remember how long it took us to be comfortable with K8s? Now your HTTPRoute setup for your Gateway API implementation is useless, your HPA scaling based on memory/CPU utilization can be thrown out of the window, you'll come across new K8s terminology like _LeaderWorkerSet_ and _DisaggregatedSet_, traditional service meshes won't help you, and all the metrics you thought were important won't matter that much anymore. TL;DR: a fun journey lies ahead!

### Why are **GPUs** all the rage now?

As far as raw resources are concerned, we've only had to deal with disk, CPU, and memory. Disk space has been a non-factor for a long time because SSDs and HDDs have become dirt cheap. Memory and CPU, on the other hand have always been considered precious resources, so our focus has been on these two.
We know that computation happens on the CPU -- so why on earth can't we keep using it for inference workloads? Those require computation, just like the server running my awesome backend rewritten in Rust, right? Well no.

![CPU vs GPU architecture](/blog/images/llm-platform-engineering-overview/gpu-vs-cpu-blog.jpg)

Without going into too much unnecessary detail about the actual hardware architecture of CPUs and GPUs, the main thing to remember is that CPUs have a **few powerful cores** that are great at executing a smaller number of complex instructions (compared to the GPU) very quickly: application logic, web servers, databases, operating systems -- so operations that require a lot of branching and complexity. GPUs, on the other hand, have **thousands of smaller cores** that are great at executing simple arithmetic operations (a LOT of them) over and over again. Spoiler alert: LLMs require the latter.

Another issue is **bandwidth**: high-end server CPUs are capable of moving a _few hundred GB_ per second from RAM (DRAM → memory controller → CPU caches (L3/L2/L1) → registers/vector units → computation), whereas GPUs are capable of moving _multiple TB_ per second from their high-bandwidth memory units towards the computation cores (HBM → GPU cache/shared memory/registers → tensor cores → computation). **HBM** stands for High Bandwidth Memory, which is specifically designed for ultra-high bandwidth and low latency, and tensor cores are a type of GPU core specialized at the hardware level to perform billions of **matrix operations** faster than any "regular" cores.

LLMs need to execute a **huge number of matrix operations** because nearly every major step in a **transformer** (where these matrix calculations take place) is built from linear algebra (bleh). Each token is represented as a **vector** of numbers, and the LLM repeatedly multiplies these vectors by large weight matrices. Since this happens across many tokens, many layers, and billions of learned parameters, a single generated token can require an enormous number of multiply-and-accumulate operations. These operations are not complex, but they happen billions of times over and over, which makes GPUs much better suited to this work because of their architecture.

![High-level architecture of traditional LLMs](/blog/images/llm-platform-engineering-overview/llm-overview.png)

It is also worth mentioning that there are models that can be run on CPUs (for example SmolLM) because their parameter counts are small enough that the amount of computation and memory movement stays manageable on a CPU. In general, **the number of parameters is strongly correlated with how much compute power is needed: more parameters mean more weights must be loaded and more multiply-accumulate operations must be performed for each token**, so larger models require much more memory bandwidth and processing throughput. SmolLM has a version that has only 135 million parameters, whereas something like Llama 3.1 405B has **405 billion parameters** -- good luck running that on your gaming CPU!

**TL;DR: GPUs are much more suited architecturally on the hardware level for the matrix operations that are needed for LLMs to calculate.**

### The model

In the previous paragraph about GPUs we have touched on a few keywords: models, parameters, vectors, transformers, and the high-level architectural overview of LLMs contain keywords like prefill, decode, tokenization, etc. Don't worry about these for now, we'll understand them later just enough so that we'll get a high level overview _enough for a platform engineer_.

LLM stands for Large Language **Model** so it would be great to understand what a **model** actually is -- for that let's see one. Spoiler alert: it's a big file with a bunch of boring N-dimensional arrays.

#### HuggingFace

[HuggingFace](https://huggingface.co) in essence is the **GitHub for models**. Here you can browse more than 2 million open-source models, as well as datasets for training models. It's best to get familiar with this website, as later on in our actual tutorials we'll use HuggingFace to download the LLM we are going to be experimenting with (also HF seems to be the industry standard for storing models as of writing this article).

#### Let's see inside a model

Let's look at the files for [SmolLM2 with 135 million parameters](https://huggingface.co/HuggingFaceTB/SmolLM2-135M/tree/main) (we could look at any other model, I chose this one for an example). As we can see there are a few configuration files, and one bigger file called **model.safetensors**:

![LLM files on HuggingFace](/blog/images/llm-platform-engineering-overview/smollm2.png)

when we talk about **the model** this is the file we are mostly referencing. _safetensors_ is a new simple format for storing tensors safely. A **tensor** essentially is a multidimensional array of numbers which are used by LLMs to store things like model weights, token embeddings, activation values, etc for matrix operations (so many complex words to understand... but we'll get there).
Unlike formats based on Python [pickle](https://docs.python.org/3/library/pickle.html) which was used in the past to store models, it does not allow arbitrary code execution when loading model weights making it safer for sharing and downloading models. It's also designed to be suuuuper fast.

To see inside the **model**, let's install the _safetensors_ Python module and the _torch_ module:

```bash
pip install safetensors torch
```

and then execute the below Python code to print the tensors from the model:

```python
from safetensors import safe_open

with safe_open("model.safetensors", framework="pt", device="cpu") as f:
    for name in f.keys():
        tensor = f.get_tensor(name)

        print(name)
        print("shape:", tensor.shape)
        print("dtype:", tensor.dtype)
        print(tensor)
        print()
```

You'll see that the model has **layers**, whose **weights** are stored as **tensors**—N-dimensional arrays of numbers. For example, here is a weight tensor from the first layer:

```text
model.layers.0.self_attn.q_proj.weight
shape: torch.Size([576, 576])
dtype: torch.bfloat16
tensor([[-0.0894,  0.1367, -0.1045,  ...,  0.4727,  0.4492,  0.1924],
        [-0.0977,  0.4258,  0.0408,  ...,  0.4902,  0.2129, -0.1865],
        [-0.1572,  0.0938, -0.2656,  ...,  0.3242,  0.3398,  0.2852],
        ...,
        [-0.1426,  0.1348,  0.3281,  ..., -0.1206, -0.1582, -0.2021],
        [ 0.1309, -0.0386,  0.3516,  ...,  0.1797, -0.2520,  0.1611],
        [-0.1367,  0.1309,  0.3574,  ..., -0.0957, -0.1592, -0.2227]],
       dtype=torch.bfloat16)
```

If you expected to see a lot of interesting stuff inside a model code, now you must be disappointed -- **it's just a bunch of numbers**!
