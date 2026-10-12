---
title: "LLM Inference Platform Engineering - Part 1 - Overview"
date: 2026-10-10T18:00:00+02:00
description: "The first part of my LLM Inference Platform Engineering series, providing a high-level overview of the inference process."
tags: ["LLM", "Inference", "GPU", "Overview"]
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
6. **Stage 6:** OMG, this is really expensive, we are limiting everyone to X dollars per month (where X gets spent in a week)!
7. **Stage 7:** Couldn't we just host it ourselves using open-source models and "only pay for the infra"?

Stage 7 might have to wait a bit for a few companies -- but I have a really strong hunch that this is going to be the case for most, and we want to be ready. This series is intended to cover my understanding of the current landscape and to solidify some of what I've learned. The thing that's hard about this in general is the fact that as platform engineers, we have to understand **so much stuff**, and now there's a whole new area we need to dig into. Remember how long it took us to be comfortable with K8s? Now your HTTPRoute setup for your Gateway API implementation is useless, your HPA scaling based on memory/CPU utilization can be thrown out of the window, you'll come across new K8s terminology like _LeaderWorkerSet_ and _DisaggregatedSet_, traditional service meshes won't help you, and all the metrics you thought were important won't matter that much anymore. TL;DR: a fun journey lies ahead!

NOTE: This particular article is going to be a bit dense and won't contain many follow-along examples, but the truth is that we must understand many things about LLM architecture well enough (_as platform engineers we don't really care about the underlying math of the models, SoftMax functions, tensor transformations and so on_) to be able to reason about operating + debugging + observing + serving them.

## Why are GPUs all the rage now?

As far as raw resources are concerned, we've only had to deal with disk, CPU, and memory. Disk space has been a non-factor for a long time because SSDs and HDDs have become dirt cheap. Memory and CPU, on the other hand have always been considered precious resources, so our focus has been on these two.
We know that computation happens on the CPU -- so why on earth can't we keep using it for inference workloads? Those require computation, just like the server running my awesome backend rewritten in Rust, right? Well no.

![CPU vs GPU architecture](/blog/images/llm-platform-engineering-overview/gpu-vs-cpu-blog.jpg)

Without going into too much unnecessary detail about the actual hardware architecture of CPUs and GPUs, the main thing to remember is that CPUs have a **few powerful cores** that are great at executing a smaller number of complex instructions (compared to the GPU) very quickly: application logic, web servers, databases, operating systems -- so operations that require a lot of branching and complexity. GPUs, on the other hand, have **thousands of smaller cores** that are great at executing simple arithmetic operations (a LOT of them) over and over again. Spoiler alert: LLMs require the latter.

Another issue is **bandwidth**: high-end server CPUs are capable of moving a _few hundred GB_ per second from RAM (DRAM → memory controller → CPU caches (L3/L2/L1) → registers/vector units → computation), whereas GPUs are capable of moving _multiple TB_ per second from their high-bandwidth memory units towards the computation cores (HBM → GPU cache/shared memory/registers → tensor cores → computation). **HBM** stands for High Bandwidth Memory, which is specifically designed for ultra-high bandwidth and low latency, and tensor cores are a type of GPU core specialized at the hardware level to perform billions of **matrix operations** faster than any "regular" cores.

LLMs need to execute a **huge number of matrix operations** because nearly every major step in a **transformer** (where these matrix calculations take place) is built from linear algebra (bleh). Each token is represented as a **vector** of numbers, and the LLM repeatedly multiplies these vectors by large weight matrices. Since this happens across many tokens, many layers, and billions of learned parameters, a single generated token can require an enormous number of multiply-and-accumulate operations. These operations are not complex, but they happen billions of times over and over, which makes GPUs much better suited to this work because of their architecture.

It is also worth mentioning that there are models that can be run on CPUs (for example SmolLM) because their parameter counts are small enough that the amount of computation and memory movement stays manageable on a CPU. In general, **the number of parameters is strongly correlated with how much compute power is needed: more parameters mean more weights must be loaded and more multiply-accumulate operations must be performed for each token**, so larger models require much more memory bandwidth and processing throughput. SmolLM has a version that has only 135 million parameters, whereas something like Llama 3.1 405B has **405 billion parameters** -- good luck running that on your gaming CPU!

**Takeaway**: GPUs are much more suited architecturally on the hardware level for the matrix operations that are needed for LLMs to calculate, so you'll be using them.

## The model

In the previous paragraph about GPUs we have touched on a few keywords: models, parameters, vectors, transformers, etc. Don't worry about these for now, we'll understand them later just enough so that we'll get a high level overview _enough for platform engineers_.

LLM stands for Large Language **Model** so it would be great to understand what a **model** actually is -- for that let's see one. Spoiler alert: it's a big file with a bunch of boring N-dimensional arrays.

### HuggingFace

[HuggingFace](https://huggingface.co) in essence is the **GitHub for models**. Here you can browse more than 2 million open-source models, as well as datasets for training models. It's best to get familiar with this website, as later on in our actual tutorials we'll use HuggingFace to download the LLM we are going to be experimenting with (also HF seems to be the industry standard for storing models as of writing this article).

### Inside the model file

Let's look at the files for the [SmolLM2 with 135 million parameters](https://huggingface.co/HuggingFaceTB/SmolLM2-135M/tree/main) model (we could look at any other model, I chose this one for an example). As we can see there are a few configuration files, and one bigger file called **model.safetensors**:

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

If you expected to see a lot of interesting stuff inside the model code, now you must be disappointed -- **it's just a bunch of numbers**! These are the numbers that are learned via [model training](https://www.ibm.com/think/topics/llm-training) that define how a certain input will produce the required output:

![Overly-simplified way of looking at models](/blog/images/llm-platform-engineering-overview/simplified-overview-model.png)

**Takeaway**: A model is nothing but a **file** which contains a bunch of numbers in N-dimensional arrays. These numbers were learned via model training, and are applied to your input to produce the correct output. We use HuggingFace for storing, distributing and downloading models (we can also store these locally in _PersistentVolumes_ or in cloud object stores), and these models use the .safetensors extension.

## LLM high-level overview

Now that we know why GPUs are used to run LLMs and we know that a model is nothing but a bunch of learned numbers, it's time to look at the high level flow of an LLM and focus-in on the important parts that we'll care about later:

![LLM high level architecture](/blog/images/llm-platform-engineering-overview/llm-overview.png)

### Inference

Whenever I saw the word **inference** I couldn't really tell what this really meant in the context of LLMs (maybe because I'm not a native english speaker, so it didn't really come across as self-explanatory). "During inference, the model does XYZ...." great but what the heck is inference? The definition of **infer** is to derive or conclude something from available information. When we talk about model inference, we talk about the whole process of feeding an **input** to a **model** so that it can use its **weights** it has learned during training to **infer** the output.

When we prompt the LLM with

```text
Ey yo, hows the weather in Hungary?
```

it will infer an output by running our input through the model using its already-trained weights:

```text
input (Ey yo, how's the weather in Hungary?)
  ↓
black box of magic and a lots of maths
  ↓
generated output (The weather is sunny in Hungary, yo!)
```

The whole process of running the trained model to produce an output is called inference.

**Takeaway**: The word **inference** refers to the process of actually running the model and getting the output based on the inputs.

### Tokenization and Embeddings

**Tokenization** is the process of splitting the input text (aka. your prompt) into smaller units called _tokens_ which are then converted into simple numbers. Let's see it in an example where we'll see the token representations of the prompt _"Hello, how are you?"_.

Install the transformers Python package:

```bash
pip install transformers
```

and then execute the following code:

```python
from transformers import AutoTokenizer

# We use a tokenizer from the model Qwen2.5-0.5B-Instruct,
# but this could be almost any model with a pretrained tokenizer.
tokenizer = AutoTokenizer.from_pretrained("Qwen/Qwen2.5-0.5B-Instruct")

# This is your input (prompt)
text = "Hello, how are you?"

ids = tokenizer.encode(text)

print("Token IDs:", ids)
print("Tokens:", tokenizer.convert_ids_to_tokens(ids))
```

it will print this:

```text
Token IDs: [9707, 11, 1246, 525, 498, 30]
Tokens: ['Hello', ',', 'Ġhow', 'Ġare', 'Ġyou', '?']
```

so now we can see how the input is split into tokens (be aware that a token does not equal a word -- most of the time it's actually smaller than a word!) and mapped to numbers. So the words are represented as the following numbers:

```text
Hello -> 9707
, -> 11
how -> 1246
are -> 525
you -> 498
? -> 30
```

Great but what now, you might ask. Well the model cannot really do anything with these integer numbers -- remember how everything in a model is represented as matrices (**n-dimensional matrices aka. tensors**). So now comes the **embedding** part.
The models all have a big **table** where each ID is mapped to an **embedding vector**. For example if the model uses embeddings with 4 dimensions (_the number of dimensions for these embeddings are different for models, e.g for Qwen2.5-0.5B the hidden dimension is 896, so these tokens are represented by 896 dimensional tensors, not just 4 like in the below example_):

```text
9707 → [ 0.8, -0.2,  0.4,  0.1 ]  # hello's embedding vector
1246 → [ 0.7, -0.3,  0.5,  0.0 ]  # how's embedding vector
525 → [-0.4,  0.9, -0.1,  0.8 ]   # are's embedding vector
498 → [ 0.1,  0.3,  0.7, -0.6 ]   # you's embedding vector
```

This **embedding table is part of the model's learned weights**, so it is another tensor inside the `model.safetensors` file we looked at earlier. Its shape is `[vocabulary size, embedding dimension]`: one row for each token ID, with each row containing that token's vector. Training learns these numbers, during **inference** the embedding layer just looks up the rows for our input tokens.

Now our token IDs have become vectors that the transformer layers can process. Wooohoo! But **the lookup itself doesn't account for context yet**. For example, if `bank` has the same token ID in "river bank" and "bank account", it starts with the same embedding vector in both. The transformer layers then **use the surrounding tokens to build different, context-dependent representations**. We don't need to dive deeper into that, but it's good to know.

![Tokenization and Embedding](/blog/images/llm-platform-engineering-overview/tokenization-embedding.png)

The embedding table takes up some memory as well. [Qwen2.5-0.5B's configuration](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct/blob/main/config.json) specifies **151,936** vocabulary entries and **896** dimensions. That's `151,936 × 896 = 136,134,656` parameters -- roughly **260 MiB at two bytes per parameter**, just for the input embedding table!

(NOTE: you'll also hear about **embeddings for semantic search and RAG**. Here we're talking about the LLM's **internal, per-token embedding lookup**. Search systems typically use an embedding model to produce a vector representing a whole query or text chunk, which can then be compared with other vectors.)

One last thing to mention about **tokenization** is that usually this is done by the **CPU**. If we think back to the first point about why GPUs are used for LLMs, we've learnt that because they are really good at executing billions of **simple operations** like matrix multiplication and simple math stuff in parallel. However in the process of tokenization, there are a lot of lookups, string manipulations, branching, etc. -- so **complex operations which the CPU is awesome at**.

On a very oversimplified level the flow is something like:

```text
input text -> tokenizer (CPU runs it) -> token IDs [9707, 11, 1246, 525, 498, 30]
-> transfer token IDs to GPU -> model's embedding layer looks up the embedding vectors
-> transformer layers start the work
```

There are some cases when tokenization is run on the GPU as well, when dealing with massive scale. For example NVIDIA has released some tokenizers that run on GPUs, if you are interested go ahead and research it.

**Takeaway**: Tokenization is the process where your prompt for the LLM is turned into simple numbers (work done by the CPU). Embedding is where these numbers' vector representation is looked up in vector embedding matrices inside the model (GPU) that the LLM can finally work with.

### Prefill
