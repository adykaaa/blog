---
title: "LLM Inference Platform Engineering - Part 1 - Overview of the Beast"
date: 2026-10-10T18:00:00+02:00
description: "The first part of my LLM Inference Platform Engineering series, providing a high-level overview of the inference process."
tags:
    [
        "LLM",
        "Inference",
        "Attention",
        "Cache",
        "QKV",
        "Overview",
        "Model",
        "Decode",
        "Prefill",
    ]
draft: false
aliases: ["/blog/llm-platform-engineering-basics/"]
wideCode: true
toc: true
---

## Intro

Inference Platform Engineering is an area that is becoming increasingly popular due to the widespread use of LLMs everywhere. If we think about it, it makes perfect sense: you are not writing code by hand anymore, are you? :)
However, the LLM you prompt to design a rocket ship and tell "should not make mistakes pls" needs to **run somewhere**. Today, 99% of the time, you don't care where. You just fire up Claude or the latest version of ChatGPT, which reads your prompt, waits a bit, and spits out the answer -- so you might ask: why would I even need to understand this?

The answer is simple: **this is not going to stay like this for long**. If you are working as part of an organization (mid-sized or big), you might have gone through the following stages (flawlessly communicated by your leadership):

1. **Stage 1:** LLMs are dangerous. We need to use them with caution!
2. **Stage 2:** LLMs are super capable. Let's ship more features!
3. **Stage 3:** Our whole company is an AI-first company now (which is super unique because every other company is an AI-first company now, and these two letters are attracting VC money like blood attracts sharks).
4. **Stage 4:** We are counting how many tokens you are using and we'll make it part of your performance evaluation to make sure you are using AI a lot! (ffs...)
5. **Stage 5:** Well... this is costing us a lot of money now, so please use it carefully: only use higher-tier models if necessary, and use the dumber models for everything else.
6. **Stage 6:** OMG, this is really expensive. We told everyone to use AI for everything, and they did! What a shocker. Meanwhile Anthropic and OpenAI are raising prices like there's no tomorrow... ok, we are limiting everyone to X dollars per month (where X gets spent in a week) to stop this madness.
7. **Stage 7:** People are complaining that they reach the $ limit too fast, we are spending way too much on this... Couldn't we just host a few models ourselves using open-source models and "only pay for the infra"?

Stage 7 might have to wait a bit for a few companies -- but I have a really strong hunch that this is going to be the case for most, and we want to be ready. This series is intended to cover my understanding of the current landscape and to solidify some of what I've learned. The thing that's hard about this in general is the fact that as platform engineers, we have to understand **so much stuff**, and now there's a whole new area we need to dig into. Remember how long it took us to be comfortable with K8s? Now, your `HTTPRoute` setup for your Gateway API implementation is useless. Your `HPA` scaling based on memory/CPU utilization can be thrown out of the window. You'll come across new K8s terminology like `LeaderWorkerSet` and `DisaggregatedSet`. Traditional service meshes won't help you, and you'll come across a ton of new metrics (related to GPU) that will be the heart of operating LLMs. TL,DR: a fun journey lies ahead!

You could ask me who the target audience for this series really is.... and honestly? **Me**. I realized that I solidify concepts much more easily if I write them down -- but I also believe platform engineers who have experience in the field but don't know anything about inference engineering will also benefit from this (_or at least I hope_). This means that throughout my posts I'm not going to explain basic concepts related to K8s, monitoring, distributed systems, etc. -- only those that are related to what a particular article is about.

This article in particular is going to be **dense and theory-heavy** and won't have a lot to do with platform engineering, but the truth is that we must understand many things about LLM inference architecture just enough (_as platform engineers, we don't really care about the underlying math of the models, SoftMax functions, tensor transformations and so on_) to be able to reason about **operating + debugging + observing + serving** them. I'll try to focus in on the important and fundamental parts.
Don't worry, in the **upcoming parts** of the series we'll actually deploy stuff into K8s, have awesome dashboards in Grafana, understand model serving, special load balancing, and more.

For the really lazy readers (**I'm talking about you, Dhruv**), every section will have a short Takeaway.

So let's roll.

## Why are GPUs all the rage now?

As far as raw resources are concerned, we've only had to deal with disk, CPU, and memory. Disk space has not been an issue for a long time because SSDs and HDDs have become dirt cheap (_unless we are talking about huge scale_). Memory and CPU, on the other hand, have always been considered precious resources because VMs are expensive, so our focus has been on these two -- however, all you keep hearing about is how expensive GPUs are because of AI, models run on GPUs, you need to take a loan to buy a damn RTX 5070 to be able to play games on high res, and so on.
We know that for the workloads we are used to, computation happens on the CPU -- so why on earth can't we keep using it for LLM workloads? Those require computation, just like the server running my awesome backend rewritten in Rust, right? Well, no.

### Cores and memory bandwidth

![CPU vs GPU architecture](/blog/images/llm-platform-engineering-overview/gpu-vs-cpu-blog.jpg)

Without going into too much detail about the actual hardware architecture of CPUs and GPUs, the main thing to remember is that **CPUs** have a **few powerful cores** that are great at executing a smaller number of complex instructions (compared to the GPU) very quickly: application logic, web servers, databases, operating systems -- so operations that require a lot of branching and complexity. **GPUs**, on the other hand, have **thousands of smaller cores** that are great at executing simple arithmetic operations (a LOT of them) over and over again. Spoiler alert: LLMs require the latter.

Another issue is **bandwidth**: high-end server CPUs are capable of moving a _few hundred GB_ per second from RAM (DRAM → memory controller → CPU caches (L3/L2/L1) → registers/vector units → computation), whereas GPUs are capable of moving _multiple TB_ per second from their high-bandwidth memory units towards the computation cores (HBM → GPU cache/shared memory/registers → tensor cores → computation). **HBM** stands for High Bandwidth Memory, which is specifically designed for ultra-high bandwidth and low latency, and tensor cores are a type of GPU core specialized at the hardware level to perform billions of **matrix operations** faster than any "regular" cores.

### Matrix operations, model size, GPU numbers

LLMs need to execute a **huge number of matrix operations** because nearly every major step in a **transformer** (where these matrix calculations take place) is built from linear algebra (bleh). Each token is represented as a **vector** of numbers, and the LLM repeatedly multiplies these vectors by large weight matrices. Since this happens across many tokens, many layers, and billions of learned parameters, a single generated token can require an enormous number of multiply-and-accumulate operations. These operations are not complex, but they happen billions of times over and over, which makes GPUs much better suited to this work because of their architecture.

GPU numbers we generally care about:

- **compute** (how much math the GPU can do, measured in FLOPS)
- **capacity** (how much data, including model weights, fits in GPU memory. Measured in GB or TB of `VRAM`.)
- **bandwidth** (how fast the GPU can read its own memory, measured in `GB/s` or `TB/s`)

As we'll learn later, there are certain operations in an LLM that benefit a LOT from high **capacity + bandwidth**, but compute doesn't really move the needle for them. There are also operations where **compute** is king.

It is also worth mentioning that there are models that can be run on CPUs (for example, SmolLM) because their parameter counts are small enough that the amount of computation and memory movement stays manageable on a CPU. In general, **the number of parameters is strongly correlated with how much compute power is needed: more parameters mean more weights must be loaded and more multiply-accumulate operations must be performed for each token**, so larger models require much more memory bandwidth and processing throughput. SmolLM has a version that has only 135 million parameters, whereas something like Llama 3.1 405B has **405 billion parameters** -- good luck running that on your gaming CPU!

### Takeaway

GPUs are much more suited architecturally on the hardware level for the matrix operations that are needed for LLMs to calculate, so you'll be using them. To determine what kind of a GPU you need, you'll look at its compute, capacity, and bandwidth numbers -- depending on your use case.

## The model

In the previous paragraph about GPUs, we have touched on a few keywords: models, parameters, vectors, transformers, etc. Don't worry about these for now. We'll understand them later just enough so that we'll get a high-level overview _enough for platform engineers_.

LLM stands for Large Language **Model**, so it would be great to understand what a **model** actually is -- for that, let's see one. Spoiler alert: it's a big file with a bunch of boring N-dimensional arrays.

### HuggingFace

[HuggingFace](https://huggingface.co), in essence, is the **GitHub for models**. Here you can browse more than 2 million open-source model repos, as well as datasets for training models. It's best to get familiar with this website, as later on in our actual tutorials we'll use HuggingFace to download the LLM we are going to be experimenting with (also HF seems to be the industry standard for storing models as of the writing of this article).

### Inside the model file

Let's look at the files for the [SmolLM2 with 135 million parameters](https://huggingface.co/HuggingFaceTB/SmolLM2-135M/tree/main) model (we could look at any other model. I chose this one for an example). As we can see, there are a few configuration files, and one bigger file called **model.safetensors**:

![LLM files on HuggingFace](/blog/images/llm-platform-engineering-overview/smollm2.png)

When we talk about **the model**, this is the file we are mostly referencing. _safetensors_ is a new simple format for storing tensors safely. A **tensor** essentially is a multidimensional array of numbers which are used by LLMs to store things like model weights, token embeddings, activation values, etc. for matrix operations (so many complex words to understand... but we'll get there).
Unlike formats based on Python [pickle](https://docs.python.org/3/library/pickle.html), which was used in the past to store models, it does not allow arbitrary code execution when loading model weights, making it safer for sharing and downloading models. It's also designed to be suuuuper fast.

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

If you expected to see a lot of interesting stuff inside the model code, now you must be disappointed -- **it's just a bunch of numbers**! These are the numbers that are learned via [model training](https://www.ibm.com/think/topics/llm-training) that define how a certain input will produce the required output. One thing to note is that each **layer** performs a lot of calculations, and then passes the result of the calculation to the next layer.

![Overly-simplified way of looking at models](/blog/images/llm-platform-engineering-overview/simplified-overview-model.png)

### Takeaway

A model is nothing but a **file** which contains a bunch of numbers in N-dimensional matrices, aka **tensors**. These numbers were learned via model training and are applied to your input to produce the correct output. We use HuggingFace for storing, distributing and downloading models (we can also store these locally in _PersistentVolumes_ or in cloud object stores btw). The file that stores the weights and the meaty stuff has the `.safetensors` extension in newer models.

## LLM flow high-level overview

Now that we know why GPUs are used to run LLMs and we know that a model is nothing but a bunch of learned numbers, it's time to look at the high-level flow of how an LLM works and focus in on the important parts that we'll care about later.

![LLM high level architecture](/blog/images/llm-platform-engineering-overview/llm-overview.png)

Once we get through this looooong article, you'll be able to reason about all parts (and more!) of the above picture, I hope.

### Inference

You will come across the word **inference** a lot, so it's good to know what it actually means. The definition of **infer** is to derive or conclude something from available information. When we talk about **LLM inference**, we talk about the whole process of feeding an **input** to a **model** so that it can use the **weights** it has learned during training to **infer** the output.

When we prompt the LLM with

```text
Ey yo, how's the weather in Hungary?
```

it will infer an output by running our input through the model using its already-trained weights:

```text
input (Ey yo, how's the weather in Hungary?)
  ↓
black box of magic and lots of maths
  ↓
generated output (The weather is sunny in Hungary, yo!)
```

The whole process of running the trained model to produce an output is called **inference**. We will dive deeper into the important parts, but one of the points I'd like to get across before diving deeper is that LLMs are nothing more than **token predictor machines**. You give it a prompt, the prompt goes through the black box of magic calculations, and it gives you an answer based on a LOT of maths and learned weights.

#### Takeaway

The word **inference** refers to the process of actually running the model and getting the output based on the inputs. LLMs are not magic. They are word predictor machines.

### Tokenization and Embeddings

**Tokenization** is the process of splitting the input text (aka your prompt) into smaller units called _tokens_ which are then converted into simple numbers. LLMs cannot work on strings because they have variable lengths, discrete symbols, and they have no useful representation in maths -- which we know is desperately needed because in LLM land everything is about matrices.

So let's see via an example how our prompts are turned into tokens with our simple prompt _"Hello, how are you?"_.

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

It will print this:

```text
Token IDs: [9707, 11, 1246, 525, 498, 30]
Tokens: ['Hello', ',', 'Ġhow', 'Ġare', 'Ġyou', '?']
```

So now we can see how the input is split into tokens (be aware that a token does not equal a word -- most of the time it's actually smaller than a word!) and mapped to numbers. So the words are represented as the following numbers:

```text
Hello -> 9707
, -> 11
how -> 1246
are -> 525
you -> 498
? -> 30
```

#### From token IDs to embedding vectors

Great, but what now, you might ask. Well, the model cannot really do anything with the above integer numbers -- remember how everything in a model is represented as matrices (**n-dimensional matrices, aka tensors**). So now comes the **Embedding** part.
The models all have a big **table** where each ID is mapped to an **embedding vector**. For example, if the model uses embeddings with 4 dimensions (_the number of dimensions for these embeddings is different for models, e.g. for Qwen2.5-0.5B the hidden dimension is 896, so these tokens are represented by 896-dimensional tensors, not just 4 like in the below example_):

```text
9707 → [ 0.8, -0.2,  0.4,  0.1 ]  # hello's embedding vector
1246 → [ 0.7, -0.3,  0.5,  0.0 ]  # how's embedding vector
525 → [-0.4,  0.9, -0.1,  0.8 ]   # are's embedding vector
498 → [ 0.1,  0.3,  0.7, -0.6 ]   # you's embedding vector
```

This **embedding table is part of the model's learned weights**, so it is just another tensor inside the `model.safetensors` file we looked at earlier. Its shape is `[vocabulary size, embedding dimension]`: one row for each token ID, with each row containing that token's vector. Training learns these numbers. During **inference** the embedding layer just looks up the rows for our input tokens to get their vector representations.

![Tokenization and Embedding](/blog/images/llm-platform-engineering-overview/tokenization-embedding.png)

FTR, the embedding table takes up some memory as well. [Qwen2.5-0.5B's configuration](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct/blob/main/config.json) specifies **151,936** vocabulary entries and **896** dimensions. That's `151,936 × 896 = 136,134,656` parameters -- roughly **260 MiB at two bytes per parameter**, just for the input embedding table!

(NOTE: you'll also hear about **embeddings for semantic search and RAG**. Here we're talking about the LLM's **internal, per-token embedding lookup**. Search systems typically use an embedding model to produce a vector representing a whole query or text chunk, which can then be compared with other vectors.)

#### Where the CPU and GPU come in

One thing to mention about **tokenization** is that usually this is done by the **CPU**. If we think back to the first point about why GPUs are used for LLMs, we've learnt that they are really good at executing billions of **simple operations** like matrix multiplication and simple math stuff in parallel. However, in the process of tokenization, there are a lot of lookups, string manipulations, branching, etc. -- so **complex operations which the CPU is awesome at**.
(There are some cases when tokenization is run on the GPU, when dealing with massive scale. For example, NVIDIA has released some tokenizers that run on GPUs. If you are interested, go ahead and research it, but you'll most likely deal with tokenization on the CPU.)

On a very oversimplified level, the **flow** is something like:

```text
input text -> tokenizer (CPU runs it) -> token IDs [9707, 11, 1246, 525, 498, 30]
-> transfer token IDs to GPU -> model's embedding layer looks up the embedding vectors
-> transformer layers start the work
```

#### Takeaway

Tokenization is the process where your prompt for the LLM is turned into simple numbers (work done by the CPU). Embedding is where these numbers' vector representations are looked up in vector embedding matrices inside the model (on the GPU) that the LLM can finally start working with in the transformer layers.

### Attention

So, now our prompt has become token **ID**s via tokenization, which then became vectors via **embedding lookups**. However, if you take a look at the above section, there's a slight problem related to maths and how words can represent different meanings based on context. **Embedding doesn't account for context**.

If we take a look at this prompt (_we will use this prompt in multiple sections, and we will assume that each word equals a token for simplicity_):

```text
Take me to the nearest OTP bank.
```

and this one:

```text
We sat down next to the river bank.
```

the token `bank` will go through the **tokenizer** and produce the same integer **ID**, and thus it will have the same **embedding vector** representations -- but the meaning of the word `bank` is completely different based on which sentence we use it in -- so LLMs need a mechanism to know the **meaning** of the word based on the **context**. This mechanism is called **attention**.

At a high level, attention lets **each token** look at the **other tokens** in our prompts and decide how relevant they are when building its next representation. Let's use our bank example again (_this article is quickly becoming an OTP ad. Unfortunately, I'm not sponsored by them..._):

```text
Take me to the nearest OTP bank.
```

When the model is processing `bank`, not every previous token is equally useful. `OTP` is probably very important because it gives us a strong hint about what kind of bank we're talking about. `Take` or `me` or `.` matters less for understanding the meaning of `bank` itself.

The model assigns a **score** to every token:

![OTP bank attention example](/blog/images/llm-platform-engineering-overview/otp-bank-att-scores.png)

These numbers are called **attention scores** and describe how much **attention** the token `bank` should pay to the **other tokens** to be able to correctly figure out the meaning of the word `bank` in the current context. In the example picture above, we can see that the model decided to give the highest attention score to OTP for the word `bank`.

Comparing this with the `We sat down next to the river bank` prompt, it would be something along the lines of:

![River bank attention example](/blog/images/llm-platform-engineering-overview/river-bank-att-scores.png)

The embedding lookup for `bank` starts from the same place and gets the same embedding vector as it did for the OTP bank example, but now tokens like `river` become much more relevant as their attention scores are the highest. Through **attention**, the model can build a completely different context-dependent representation of the same token.

The important part is that attention isn't some **magical** lookup table saying "OTP bank means a financial institution". The **model** isn't consciously reading the sentence and reasoning about which words look important, because everything is still **vectors and matrix multiplications**. The **model has learned** numerical patterns (during **training**) that tell it which token representations are useful to one another. Remember how in the small section about the meaning of **Inference** we have learned that models are just predictor machines without magic? :)

#### Causal self-attention

In the decoder-only LLMs we care about here, **each token can attend to itself and the tokens that came before it** but not to future tokens. So in

```text
Take me to the nearest OTP bank.
```

the token `nearest` only has attention scores for the token representations of `["Take", "me", "to", "the", "nearest"]` but not `bank` and `.`. This is called _causal self-attention_. There are many other types of attention mechanisms. If you are interested, read it here: [link](https://www.turingpost.com/p/attention-types).

#### Attention heads

One phrase you'll come across often is **attention head**. An attention **head** is one independent **view** of the attention calculation, so models usually have more than one attention head. This means that instead of the model doing 1 giant attention calculation for the tokens, it lets these attention heads **perform their calculations separately** based on the separate weights these heads operate with.

Why is this important? Let's suppose that for our prompt `Take me to the nearest OTP bank.` the answer the LLM spits out is `Sure thing boss. The nearest OTP bank is located on the 4th Street in the 9th District in Budapest`.

So for our prompt:

```text
Take
me -> for 1 attention head this has a high attention score because it will answer "Sure thing boss" and not "Anne / Bob should go to..."
to
the
nearest -> for 1 attention head this can have the highest attention score, because the output of the LLM might include the address for the bank
OTP -> for another attention head, this can have the highest attention score because it specifices exactly what bank we are searching for
bank -> for yet another attention head this has the highest attention score, as the entity we are searching for is a bank.
```

Each attention head calculates its own attention scores, then uses those scores to combine the `Value` vectors (which we will learn about later) into an attention output. After all, more eyes see more!

![Attention heads](/blog/images/llm-platform-engineering-overview/attention-heads.png)

Obviously, not only the token `bank` has attention scores tho -- **every token performs attention**, and thus every token has attention scores. The question is: how does the model actually decide which tokens are **relevant** to other tokens? How does it know that `OTP` and `river` are the most relevant tokens in our prompts to the token `bank`? How does it calculate **the attention scores**?

This is where `Query (Q)`, `Key (K)`, and `Value (V)` come into the picture, which we will discuss on a high level in the next section.

#### Takeaway

Attention is the mechanism that allows tokens to look at other tokens and figure out which ones are relevant. This is how the model can start with the exact same embedding for the token `bank`, but end up with a completely different representation depending on whether we're talking about an `OTP bank` or a `river bank`. There are several attention heads in a model, each giving its own attention scores for the tokens to help contribute to the output of a layer.

### Query, Key, Value, Output (Q, K, V, O)

Before we move on, the **checkpoint** we are at right now in our learning journey looks like this roughly:

0. you know **GPUs** are da bomb for performing calculations for LLMs due to their architecture. You also know that a **model** is nothing but a bunch of tensors and layers and weights
1. you prompt the LLM `Take me to the nearest OTP bank.`
2. your prompt is converted into **tokens**
3. the model looks up the **embedding vectors** for the tokens so it can start performing calculations in layers using the **weights** it has learned during training
4. you have learned about **attention**, **attention heads** and **attention scores**, but you have no idea how they come into the picture yet

This section is going to be the most **dense**, so prepare your brain. It is still not rocket science, but we'll get just a bit more involved in a few things.

#### The projection weights inside the model

Remember our tensor that we printed using Python in the earlier section about **Tokenization and Embeddings** from inside of the model?

```text
model.layers.0.self_attn.q_proj.weight
shape: torch.Size([576, 576])
[...]
```

From the first line, we can understand a few things already:

- `model` refers to the LLM.
- `layer` refers to a layer of matrix computations. Models have many layers. Generally, bigger models have more.
- `0` is the index of the layer we are looking at currently. In a model there are several layers.
- `self_attn` means self-attention, which we discussed in the previous section.
- `weights` are the numbers the model learned during training - it uses them in matrix computations to transform one vector into another.

If we take a look at the inside of the `model.safetensors` file again, we can see that in the `layers` there are `k`, `q`, `v`, and `o` projection weights:

![K,Q,V,O proj. weights](/blog/images/llm-platform-engineering-overview/koqv-proj.png)

but what the heck are these?

Recall that in our section about **attention**, we have a picture that shows attention **scores** for each token, which represent how relevant each token is in forming an understanding and building the **context-dependent** representation of another token (e.g. `OTP` has a really high attention score for the token `bank`), but we don't really know **how** that score is calculated.

The secret is that when each token arrives in the model and has gone through the embedding phase (aka. it is turned into a vector), it is modified by the values of the above weights:

```text
q_proj.weight = learned numbers used to create Queries
k_proj.weight = learned numbers used to create Keys
v_proj.weight = learned numbers used to create Values
o_proj.weight = learned numbers used to transform the attention result
```

to calculate `K`, `Q`, `V`, and `O` during **inference**.

![K,Q,V layers](/blog/images/llm-platform-engineering-overview/q-k-v-layers.png)

So what are `K`, `Q`, `V`, and `O` then? A way of thinking about them is that they are just other **vectors that carry the below information about each token**:

```text
Query = What information am I looking for in other tokens?
Key   = What kind of information do I contain? (What info do I contain that might match other tokens' Queries?)
Value = What information do I contribute to the context of another token if that token finds me relevant?
Output = Combined output of the above
```

The `Query` and `Key` are used to calculate how relevant two tokens are to each other (e.g. how relevant `OTP` is for the token `bank`), the `Value` contains the information that actually gets passed forward once that **relevance has been calculated**. `Q`, `K`, and `V` are projections of the token's current representation. `O` is produced after attention has mixed information from the relevant `V` vectors, and `o_proj` transforms that combined result back into the model's representation space.

#### Creating Q, K, and V for our bank example

I like being practical, so how about we go through an overly simplified version of what we've covered in this section with our good ol' **OTP bank example E2E**?

Let's say that each of the words in our prompt is a token:

```text
Take
me
to
the
nearest
OTP
bank
.
```

By the time a token reaches an **attention layer**, the token is represented as a **vector**. The attention layer takes this vector and calculates `Q`, `K`, and `V` for each token (using `q_proj.weight`, `k_proj.weight`, and `v_proj.weight` that are part of the model):

```text
Take     -> Q_take,     K_take,     V_take
me       -> Q_me,       K_me,       V_me
to       -> Q_to,       K_to,       V_to
the      -> Q_the,      K_the,      V_the
nearest  -> Q_nearest,  K_nearest,  V_nearest
OTP      -> Q_OTP,      K_OTP,      V_OTP
bank     -> Q_bank,     K_bank,     V_bank
.        -> Q_dot,      K_dot,      V_dot
```

#### Comparing Queries and Keys

Let's say we are interested in following the token `bank`.
We also assume that our LLM uses **causal self-attention**, which means that a **token is only allowed to look at itself and the tokens before it**. In the case of bank, these are all the tokens in our prompt except for the `.` (which would not matter a lot anyways).

As we've learned, `Query` asks the question: what information am I looking at in other tokens? `Key` answers `Query`'s question: _"Hey this is the info I contain!"_ so `bank`'s `Query` is compared with the `Key` of **every token** it is allowed to see:

```text
// the "·" operator means dot product of two vectors -- the result is a single number
Q_bank · K_take
Q_bank · K_me
Q_bank · K_to
Q_bank · K_the
Q_bank · K_nearest
Q_bank · K_OTP
Q_bank · K_bank
```

for the sake of the example, let's assume

```text
Q_bank = [2.0, 1.0]
```

and the keys the model calculated are:

```text
K_take    = [0.0, 0.2]
K_me      = [0.1, 0.0]
K_to      = [0.2, 0.1]
K_the     = [0.2, 0.2]
K_nearest = [0.8, 0.6]
K_OTP     = [1.5, 1.2]
K_bank    = [0.6, 0.8]
```

the **dot product** of the two matrices for the token `OTP` is (where we see how much the `Key` of `OTP` answers the query of `bank`):

```text
Q_bank · K_OTP ->

[2.0, 1.0] · [1.5, 1.2]
= (2.0 × 1.5) + (1.0 × 1.2)
= 4.2
```

the dot product of the two matrices for the token `me` is (where we see how much the `Key` of `me` answers the query of `bank`):

```text
Q_bank · K_me ->

[2.0, 1.0] · [0.1, 0.0]

= (2.0 × 0.1) + (1.0 × 0.0)

= 0.2
```

so as we can see, the `Key` of the token `OTP` matches the `Query` of `bank` much more strongly than the `Key` of the token `me` (as 4.2 is much bigger than 0.2). The layers do the above calculation for each token, so it will look like this:

```text
raw score
Take                0.2
me                  0.2
to                  0.5
the                 0.6
nearest             2.2
OTP                 4.2
bank                2.0
```

After some **maths**, these scores are turned into percentages:

```text
Take        3.4%
me          3.4%
to          4.2%
the         4.5%
nearest    14.1%
OTP        58.0%
bank       12.2%
```

Now these look similar to the attention scores we've touched on in the **Attention** section! We are free to read this as: the token `bank` is paying around **58%** of its attention to the token `OTP`, whilst only paying **3.4%** of its attention to the token `me` in this **attention head**.

#### Mixing Values and producing the Output

Cool, so now we have these attention percentages, but we seem to be missing the use of `V` and `O`.
As we've touched on earlier, every token also carries a calculated `Value` (_what info do I contribute if another token finds me relevant -- what's my value?_).

Let's say these are the calculated `Values` for the tokens `bank` can look at in this attention head:

```text
V_take    = [0.1, 0.0]
V_me      = [0.0, 0.1]
V_to      = [0.1, 0.1]
V_the     = [0.0, 0.1]
V_nearest = [0.4, 0.3]
V_OTP     = [1.0, 0.8]
V_bank    = [0.6, 0.7]
```

the model essentially takes our beautiful attention percentages it has calculated from `Q` and `K` and applies `V` onto them:

```text
3.4%  × V_take
+
3.4%  × V_me
+
4.2%  × V_to
+
4.5%  × V_the
+
14.1% × V_nearest
+
58.0% × V_OTP
+
12.2% × V_bank
```

which will produce a single value (vector): `[0.72, 0.60]` which is called the **attention output for the token `bank`** for **one** attention head. Then the model takes **all** of these attention **outputs** from **all the attention heads** from within a layer and uses the `o_proj.weight` to do some math on them which then produces `O` aka. the `Output` of the **attention part of the layer**. This `O` is not the final output of a layer, and deffo not the final output that will come up on your screen though.

Here's a **diagram** I generated with ChatGPT about the above to get the flow across:
![K,Q,V layers](/blog/images/llm-platform-engineering-overview/attention-flow-bank.png)

To produce the LLM's final answer, however (_"Sure thing boss..."_), it goes through **more maths**: the `Output` is transformed as part of something called the **LM Head** and produces **logits** (_the model’s raw unnormalized scores for each possible next token before they’re converted into probabilities_), and then, based on how the model is configured to select from the tokens (there are multiple possible token selection strategies and algorithms), it will start displaying the output. This is maths that we don't need to really care about, and we can look at it as a black box. If you are interested:

- good article on [logits](https://illuri-sandeep5454.medium.com/logits-vs-probabilities-understanding-neural-network-outputs-clearly-0e86a4256a0e)
- good article on [token selection](https://machinelearningmastery.com/the-statistics-of-token-selection-logits-temperature-and-top-p-walkthrough/)

#### Why on earth do you need to know this then

If you've reached this point, you might feel **betrayed**. At the beginning of the article I told you that we will get just enough info as platform engineers to have a sufficient amount of understanding for inference, and now you've seen variables such as `Q`, `K`, `V`, you've seen matrix operations, probabilities, attention, etc.

The point I'd like to get across in this section (_besides you not showcasing the surprised Pikachu face when someone mentions any of these words_) is how **computationally heavy** and **memory demanding** calculating `Q`, `K`, `V`, and `O` is **for a single token** in a relatively big model.
`Llama 3.1-70B` (8,192 dimensions, 80 layers, 64 attention heads, etc.) performs more than **70 BILLION!!!** scalar multiplications for pushing **1 token through**.... out of these, more than **12 BILLION** operations are used for calculating the `Q`, `K`, `V`, and `O` projections. These also need to be stored somewhere, and for `LLama 3.1-70B` `Q`, `K`, `V`, and `O` occupy ~**3MB** per token.

There’s also an important **performance consequence** hiding in all of this. When the model processes token `n+1`, its `Query` needs to attend to the `Keys` and `Values` of the tokens that came before it. **So the more tokens there are in the context, the more previous information each new token has to consider**. In practice, this means longer conversations generally make inference waaaaaay more **expensive** as they increase the work before the first token appears, and can also make each generated token slower as the context grows. Long context heavily affects both **latency** and **memory**, so the next three concepts we are about to dive head first into matter so much for understanding inference performance (prefill, decode, KV cache).

#### Takeaway

`Q`, `K`, `V`, and `O` are vector representations calculated for **every token** in **every attention layer** during inference using **weights** that are part of the model and were learned during training. `Q` and `K` are used to figure out which tokens are relevant to each other, `V` carries the information that gets mixed together based on that relevance, and `O` is the transformed result of the attention calculation. These calculations happen over and over again across tokens and layers, which makes them both **compute- and memory-heavy**. Token `n+1` usually needs to have access to the `Q`, `K`, `V`, and `O`s of every other token that comes before it (`0..n+1)` and itself, so a bigger context window means more work.

### Prefill

**Prefill** is the first big phase of the inference workflow. **It lasts from submitting our prompt up until the first token is returned to us in the LLM's answer**.

In practical terms, when we prompt any LLM, there is a slight **pause** before it starts streaming the answer back -- that **pause** + getting the first token back in the LLM's answer is the prefill phase. You might also notice that the **bigger your prompt, the longer the pause** -- which now should **NOT** surprise you because you know about tokenization, embedding, attention (token `n+1` needs all the stuff from tokens `0..n`), `Q`s, `K`s, `V`s, how each token needs a ton of maths (_billions or trillions of operations_) and more.

#### Parallel processing

All tokens already exist when the request arrives at the model (because your whole prompt is submitted). **Causal attention** still means each position can only see itself and earlier positions, but since all tokens are present, the **GPU can start processing our prompt in parallel!** (instead of _autoregressively_, which we will come back to in the next section).
In every attention layer, `Q`, `K`, and `V` are calculated **for all tokens at the same time**, every token’s `Q` is compared against the `K`s of the tokens it is allowed to see, `V`s get mixed, `o_proj` does its thing, and the result moves on to the next layer:

![Parallel prefill](/blog/images/llm-platform-engineering-overview/prefill-parallel.png)

This parallel processing is really **important**. Back in our **GPU section** I said that there's a part of inference which is really **compute heavy** -- well guess what, it's **prefill**.
On a super high level, during prefill the **model** gets loaded out of the `VRAM` (in batches) **once** into the arithmetic units and caches, and then **thousands of GPU cores** (the specialized _tensor_ cores we've touched on) start firing **at the same time** for all of our input tokens to do the calculations required to produce the first token:

![Model load once](/blog/images/llm-platform-engineering-overview/gpu-arith.png)

We can see that prefill moves a huge amount of data from the GPU's `HBM` (High Bandwidth Memory), but it gets much more computation out of every byte it moves. This high arithmetic intensity is why prefill tends to be **limited by compute** (_TFLOPS of your GPU_) rather than **memory bandwidth**.

The most precise phrasing would be to say that the calculations are firing for the whole **input context**, not just your input tokens. If a chatbot LLM has something in its context by default (`You are a helpful chat assistant. Here's a thousand page summary of our products' FAQ: [...]`) then it also gets processed alongside our prompt `How can I refund this garbage lawnmower?` in an unoptimized system (in a real production system the system prompt is cached, but more on this later).

You might also ask the question: **why does this phase only compute the first output token in the LLM's answer**?

The answer comes down to **what we've learnt so far**. If we have a prompt:

```text
Take me to the nearest OTP bank.
```

and e.g. the output of the LLM is:

```text
Sure thing [....]
```

All of the tokens are run through in parallel from the input during prefill (because all of the tokens are known before compute time as the user inputs them at once), the calculations happen, and then a new token gets picked by the model as the first token of the answer. To generate the next token, however (the second one -- `thing`), the model needs to know what the first token was (remember **attention** and everything?). So for `Sure` to be generated, the model needed the calculations for `["Take", "me", "to", "the", "nearest", "OTP", "bank", "."]` which were knocked out in parallel, but for the second token of the answer it now needs `["Take", "me", "to", "the", "nearest", "OTP", "bank", ".", +++ ->"Sure"]` and so on. As we can see, generating the answer becomes **sequential** because only 1 new token appears in the answer each time. This sequential token generation is part of a process called **decode** and is gonna be our next section.

#### TTFT

One important metric that we need to take note of is `TTFT` (**Time To First Token**). As highlighted in the definition of prefill, it lasts from sending all of our input tokens to the LLM up until the first token shows up.

`TTFT` is important because it highly impacts UX. If your users have to wait for 30 seconds for an answer to show up, they are going to start complaining (rightfully so).

You might think that `TTFT` is only affected by the speed of **prefill** (aka. how fast those thousand GPU tensor cores can do the calculations to come up with the first token of the answer), but in real production systems this is not the case. There are several optimizations we are going to touch on in a later article (like queueing, batching, prefix caching, intelligent scheduling, etc.) that are also part of calculating `TTFT`, but more on this later.

One really trivial question has not been asked so far, however. **Why is this phase called prefill**? What are we prefilling? Stay tuned to find out.

#### Takeaway

Prefill is the first big model-execution phase of inference. It processes the (_uncached_) input context across token positions in parallel and produces the first output token. Because the GPU can reuse chunks of model weights (loaded from HBM) across many token calculations, prefill has high arithmetic intensity and is heavily **compute-bound**, not **memory bandwidth bound**. `TTFT` (Time To First Token) is an important metric that impacts UX.

### Decode

Decode is the second and final big phase of the inference workflow where the output tokens are generated (aka. the LLM answers your prompt). From the **prefill** section we've already touched on the fact that the **decode phase is sequential** by nature, meaning the LLM's answer is generated one token at a time -- the reason for this is (as we've mentioned a thousand times already) that token `n+1` needs to have the information of all tokens before it (`(0..n)`). The way you'll hear this phrased is **autoregressive token generation**:

![Decode gif](/blog/images/llm-platform-engineering-overview/decode-gif.gif)

This also brings up an interesting point about **GPU resource usage** and what the **bottlenecks** are. Remember that in our GPU section we said that the GPU numbers we generally care about are:

- compute
- capacity
- memory bandwidth

The model-weight capacity requirement is basically the same for prefill and decode: the model still has to fit into GPU memory (_but total memory usage isn't necessarily the same, because there are other things occupying VRAM as well, but we'll get to this in the next section_)

During **prefill** we have many input tokens to process at the same time. As the GPU reads model weights from HBM, those weights can be reused to perform calculations across many input token positions in parallel. In other words, we get a LOT of maths done for every byte of model data we move from HBM to the arithmetic units. This gives prefill relatively **high arithmetic intensity**, which means that for sufficiently large prompts **compute is generally the bottleneck**.

For **decode**, however, the resource constraints change quite a bit. To be absolutely clear, decode uses the exact same things in the model as prefill for coming up with the next token: it uses the same GPU cores for compute, the same model weights, calculates attention, `Q`, `K`, `V`, `O`, uses the `LM head`, produces `logits`, chooses the output token based on the selection algorithm, etc. etc., **but instead of doing it for multiple tokens, it does it for only one at a time** (_the next streamed output token as the result of autoregressive generation_). This means that for each produced output token, the GPU has to load the model, do a bit of maths, produce the output token, and then repeat -- resulting in **high memory bandwidth usage** but underutilizing **compute** resources compared to prefill.

![Decode vs Prefill GPU resources](/blog/images/llm-platform-engineering-overview/prefill-vs-decode-gpu-resources.png)

#### TPOT

We've had an important metric for prefill called `TTFT` (Time To First Token). We also have a really important one for decode called `TPOT` (_Time Per Output Token_). `TPOT` measures approximately how long the model takes to generate each additional output token during the decode phase. E.g. if `TPOT` is measured to be `50 ms/token`, it means that it produces `20 tokens per second`.

This is quite an important metric of decode, because it has really strong UX implications. If your users have to wait an eternity for the answer to come up, they'll be mad. A slow `TTFT` feels like the LLM froze trying to process our request, a slow `TPOT` feels like the LLM is really struggling to come up with the answer. Both of these are terrible.

#### Wasted work?

If you've gone through the prefill section and the decode section this far and you haven't shouted at your monitor saying **WE ARE WASTING SO MANY RESOURCES FOR EACH TOKEN THAT WE CALCULATE DURING DECODE!!**, you might need to re-read things again.

If I have an input context of `100.000` tokens, **prefill** calculates the `Q`s, `K`s, `V`s and all that stuff for them, produces the first output token, and then, to produce the second output token, **decode needs all the `Q`s, `K`s, `V`s, etc. for `100.001` tokens only to generate the second output token**. Since we know from our section on **attention** that this is true, does that mean that we are running the same calculations every single time + the calculation required for the new output token -- wasting a ton of work in each iteration? Fortunately, engineers designing LLMs are much smarter than that, and they have come up with a really simple proposition:

```text
Why don't we simply store the already calculated values somewhere,
so that only the new stuff needs to go through computation again?
```

Where we store these will be revealed in the next section.

#### Takeaway

Decode is the phase where each output token in our LLM's answer gets generated sequentially. Prefill gets lots of computation out of each chunk of data moved from HBM to the compute units, decode gets relatively little computation out of each chunk of data moved and needs to move much more frequently. Hence prefill is compute-bound, while decode is memory-bandwidth-bound. `TPOT` is an important metric describing the performance of decode.

### KV Cache

Finally the section that answers two of the questions left hanging from both **prefill** and **decode**:

- why is prefill called **prefill**? What does it prefill?
- where do we **store the already calculated stuff** so that autoregressive token generation during decode only needs to calculate new stuff?

The answer to both of these is the `KV Cache`. Prefill is called prefill because it _prefills the KV cache after it runs for all of the input context tokens in parallel_ so we are not throwing away stuff we already calculated -- **decode** will reach into this cache for values (and also fill this cache when it generates output tokens).

#### Why only `K` and `V` Cache?

What a weird yet simple name... `KV Cache`. Now you must be thinking: why only `K` and `V` cache? Why not `QKVO Cache`?

During computation, all of the `Q`, `K`, `V`, and `O`s are calculated for the input context for every token that the model is processing. Let's step back to the definitions for a sec:

```text
Query = What information am I looking for in other tokens?
Key   = What kind of information do I contain? (What info do I contain that might match other tokens' Queries?)
Value = What information do I contribute to the context of another token if that token finds me relevant?
Output = Combined output of the above
```

According to these (_and what we've learned in that section hopefully_) definitions, we can see that once the next token goes through processing there are two of the above vectors that will remain unchanged after the calculations, no matter the token we are processing them for: `K` and `V` because they describe what a token **contains** irrespective of what another token is looking for.

Back to the bank example :) let's say we've already processed:

```text
Take me to the nearest OTP bank.
```

and the model has generated the first token of our answer:

```text
Sure
```

`Sure` gets a hot new `Q`:

```text
Q_sure = What information does "Sure" need from the tokens before it?
```

`Q_sure` needs to compare itself against the `K`s of all the previous tokens:

```text
K_take
K_me
K_to
K_the
K_nearest
K_OTP
K_bank
K_dot
```

these comparisons tell the **attention mechanism** which previous tokens are **relevant for** `Sure`. Once it figures it out, it uses their corresponding `V`s:

```text
V_take
V_me
V_to
V_the
V_nearest
V_OTP
V_bank
V_dot
```

to actually retrieve the **information contributed by those tokens**.

To be fair the previous tokens' `Q`s and `O`s haven't changed either, the difference is that we just don't care about them anymore.
E.g `Q_OTP` represented what `OTP` was looking for when it was being processed, but it was processed already so we don't need it anymore. When we process `Sure` we need a brand-new `Q_sure` instead. The previous `O`s have also already served their purpose while those tokens were being processed through the model, future attention operations don't need them.

The important part is that:

`K_take`, `V_take`, `K_me`, `V_me`, `K_OTP`, `V_OTP` etc. have **not changed**.

**Adding `Sure` to the end of the sequence does not suddenly change what information the previous token `OTP` contains or how future tokens should match against it**. Its `K` and `V` were calculated when `OTP` was originally processed and because of **causal attention** they remain valid for every token that comes after it.

For these reasons (_and more_) **prefill** _prefills_ the cache with `K`s and `V`s of all the tokens it has processed so that when another token goes through the model, they won't have to do these calculations over and over again in vein (of course, the new token's `K`s and `V`s are also added to the cache once the model has calculated them during decode, and so on).

So we are basically here in the process:
![Prefill KV-cache](/blog/images/llm-platform-engineering-overview/prefill-kv-cache.png)

### Decode and KV Cache

In the **decode** section we said that all work that prefill has done for calculating the tokens is not wasted, which we have proven above. We have also said that during decode the model does **autoregressive generation** meaning the process of coming up with the output tokens is mostly sequential (_there are some [optimizations and techniques](https://developer.nvidia.com/blog/an-introduction-to-speculative-decoding-for-reducing-latency-in-ai-inference/) to get around this, but we'll talk about this in a much later article_) because token `n+1` needs the info from token `0..n`.

During decode every newly generated token gets processed through the model but instead of recalculating the `K`s and `V`s for the entire context again, **the attention layers simply reach into the KV Cache and reuse the ones we've already calculated**.

After prefill we have processed:

```text
Take me to the nearest OTP bank.
```

and our KV Cache already contains the `K`s and `V`s belonging to those tokens:

KV Cache:

```text
Take -> K_take, V_take
me -> K_me, V_me
to -> K_to, V_to
the -> K_the, V_the
nearest -> K_nearest, V_nearest
OTP -> K_OTP, V_OTP
bank -> K_bank, V_bank
. -> K_dot, V_dot
```

prefill also generated the first output token:

```text
Sure
```

Now decode needs to process `Sure` in order to figure out what comes **next**. The model calculates the new token's `Q`, `K` and `V`:

```text
Sure -> Q_sure, K_sure, V_sure
```

but instead of recalculating:

```text
K_take
K_me
K_to
K_the
K_nearest
K_OTP
K_bank
K_dot
```

and all their corresponding `V`s, it simply retrieves them from the `KV Cache` so that `Q_sure` can then attend against all of those cached `K`s and use their corresponding cached `V`s! Awesome.

The model continues processing `Sure` through the rest of its layers and eventually produces the next token:

```text
thing
```

Before moving on tho **we don't throw away the newly calculated `K_sure` and `V_sure`**. We add them to the KV Cache:

```text
KV Cache:

Take     -> K_take,     V_take
me       -> K_me,       V_me
to       -> K_to,       V_to
the      -> K_the,      V_the
nearest  -> K_nearest,  V_nearest
OTP      -> K_OTP,      V_OTP
bank     -> K_bank,     V_bank
.        -> K_dot,      V_dot
Sure     -> K_sure,     V_sure      <- NEW
```

When `thing` gets processed, it gets its own fresh

```text
Q_thing
K_thing
V_thing
```

and `Q_thing` can now attend against the cached Ks and Vs of:

```text
Take
me
to
the
nearest
OTP
bank
.
Sure
```

and then add its own `K`s and `V`s, and so on until the whole decode process is finished and the answer is given by the LLM!

![Decode KV-cache](/blog/images/llm-platform-engineering-overview/decode-kv-cache.png)

and this is obviously true for **multiple prompts and long convos**. More on this in the next part.

#### KV Cache and VRAM

The cache lives in the `VRAM` of our **GPU**, alongside the **model**. The reason for this is simple: accessing the cache needs to be super fast, and should not go through unnecessary networking hops... if we had to add a networking hop or two to every KV cache access, decode would be painfully slow.

![KV Cache VRAM](/blog/images/llm-platform-engineering-overview/KV-Cache-VRAM.png)

Engineering is all about **tradeoffs** (_remember all that intense system design interview prep you were doing for your current company, where you had to showcase how senior you are by how many times you said "it depends", "trade off", "sharding", and "eventual consistency"?_), and now we have managed to **trade a compute problem for a VRAM capacity problem**. If we didn't have the **KV Cache** we would have to calculate all the values for all the tokens every time making the cores work really hard but with the cache we reduce repeated computation at the cost of consuming more memory in the long run.

In the previous parts we have learnt that prefill adds a bunch of stuff into the cache, and decode reads from the cache and also adds stuff for each token it processes. Roughly we could say:

```text
more tokens
    ↓
more K/V tensors
    ↓
larger KV Cache
    ↓
more VRAM usage
```

and the relationship is **linear with sequence length** -- so computation for 10.000 tokens requires _roughly_ twice as much space in the KV Cache as it does for 5000 tokens... **but how much exactly**?

If we look at `LLama 3.1-70B` it has

```text
80 transformer layers
8 KV heads
128 dimensions per head
BF16 = stores values in 2 bytes
```

so the equation becomes

```text
KV cache per token ≈

2                  # the cache stores both K and V
× 80               # number of layers
× 8                # number of KV heads (part of attention head we've learnt about)
× 128              # vector dimensions per head
× 2 bytes          # BF16 -- we store the values in 2 bytes (precision related stuff, will talk about it in a future article)
```

which roughly equals 327680 bytes aka. **320 KiB per token** which is insanely big! If we have a prompt + answer that equals 100.000 tokens, this becomes more than `30 GiB` from our precious `VRAM` **just for 1 request + reply for 1 user**. This fact alone brings a lot of cool engineering problems with it.

The above was just for 1 request from the user and 1 response from the LLM (so one **turn**). We obviously want to **preserve and reuse the KV state for the tokens that remain in the model's context across multiple turns**. We cannot just fill up the cache with `K`s and `V`s of just one turn and throw it away, because it would mean having to run prefill against ALL the input tokens to start generating the answer of the second turn, and so on.

This is quite logical if we think about it from a high level tho:

```text
request 1 -> response 1
request 2 -> response 2 (but LLM needs context of request 1 AND response 1 as well potentially to answer)
request 3 -> response 3 (but LLM needs context of request 1+2 AND the response 1+2 as well potentially to answer)
```

So the solution is to **keep filling the** `KV Cache` with every `K` and `V` of every request and response:
![Growing Cache](/blog/images/llm-platform-engineering-overview/growing-cache-for-turns.png)

so the cache keeps growing with the conversation.

This should also bring up a LOT of questions in you, such as:

- what should be the max size of a `KV Cache` for a user?
- do we reserve the same cache size for every user?
- when should we stop admitting in requests?
- how much `VRAM` capacity do we need for the caches? How much GPU should we pay for?
- when do we evict the `KV Cache` of a user? How long do we let it grow? (_ahhh... cache invalidation strikes again!_)
- can we reuse reserved but unitilized blocks in `VRAM` for another user's `KV Cache`?
- can we store the KV Cache more efficiently? Can we store it across multiple GPUs?

But wait, there's much more -- who wants to run inference for only 1 user? We want to be able to serve an LLM for **multiple users at the same time concurrently** which magnifies these problems even more, and brings even MORE juicy questions with it.

**Takeaway**: The `KV Cache` lives in GPU memory and stores the `K`s and `V`s of previously processed tokens so that we don't have to recalculate them during **autoregressive generation**. Its size grows roughly linearly with the number of tokens in a sequence and every active request needs **KV-cache memory of its own**.
This means GPU capacity isn't only about whether the model fits, but it also determines how much room remains for the `KV Caches` of active requests — and therefore has a **huge impact on how much concurrency an inference server can actually support**. The KV Cache also has to be read during decode, meaning it contributes not only to VRAM capacity usage but also to **memory-bandwidth pressure** as well.
