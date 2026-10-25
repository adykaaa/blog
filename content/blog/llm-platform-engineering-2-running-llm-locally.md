---
title: "LLM Inference Platform Engineering - Part 2 - Running our first LLM locally"
date: 2026-10-30T18:00:00+02:00
description: "The second part of my LLM Inference Platform Engineering series, where we'll deploy our first LLM locally into a minikube cluster, and observe some parts of it that we have learned about in the first part."
tags: ["LLM", "Grafana", "OpenLIT", "Tempo", "Dashboards"]
draft: true
wideCode: true
toc: true
---

## Intro

In [part 1](https://adykaaa.github.io/blog/llm-platform-engineering-1-inference-overview/) of the series we've gone through the **inference** process on a high level. For a quick refresher:

![LLM high level architecture](../../static/images/llm-platform-engineering-overview/llm-overview.png)

In this particular article we will go through things such as:

- deploying a model using `vLLM` into a `minikube` cluster
- observing our model
- looking into the `KV Cache`
- stressing different parts of the inference process

and more. Before we do this though, we'll need to set ourselves up for success.

## Local environment setup

The setup script I'm about to reference assumes that you are:

- running this from a **Linux** distro (WSL2 also works)
- have **Docker** installed AND running on your machine
- have an **NVIDIA** GPU in your machine with drivers and the container toolkit installed
- have 4 CPU cores and 8`GiB` of RAM available
- have sudo access
