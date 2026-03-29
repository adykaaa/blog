---
title: "What Makes a Good Internal Developer Platform?"
date: 2025-03-15
description: "Platform engineering is having a moment. But most IDPs fail for the same predictable reasons. Here's what I've learned about building platforms developers actually want to use."
tags: ["platform engineering", "developer experience", "kubernetes"]
draft: false
---

Platform engineering is having a moment. Every company above a certain size is spinning up a "platform team," every conference has a track dedicated to Internal Developer Platforms, and everyone has an opinion.

Most IDPs fail anyway.

After working on platform tooling for a while, I've noticed the failures cluster around a few predictable patterns. This post is my attempt to articulate what separates a platform developers love from one they route around.

## The golden path problem

The most common framing I hear is: "We need to build golden paths." The idea is sound — opinionated, well-lit roads that let developers ship without thinking about infrastructure. Pick one deployment mechanism, one observability stack, one networking model, and make it excellent.

The failure mode is building a golden path that's actually a golden cage.

A good golden path offers **escape hatches**. It should be easy to do the 80% case without thinking, and possible (if harder) to do the 20% case that doesn't fit the mold. The moment your platform becomes "use this or file a ticket," you've lost developer trust.

## Paved roads need owners

Infrastructure as code made it easy to spin up new services. It made it equally easy to spin up services that nobody maintains.

The platforms I've seen succeed have a clear answer to: *who is responsible for this component, and how do I reach them?*

Service catalogs like Backstage exist to answer exactly this. They're not glamorous, but a well-maintained catalog is foundational. Without it, your golden path leads into a fog of undocumented dependencies.

## Observability is a feature, not an afterthought

A platform that ships services into the void isn't a platform — it's a deployment tool. Developers need to understand what their services are doing in production from day one.

This means:
- Structured logging by default, shipped to a searchable backend
- Metrics exposed without configuration
- Distributed tracing that works across service boundaries
- Dashboards that exist before anyone asks for them

The goal is to make the right thing the default thing. If observability requires a JIRA ticket and a two-week wait, it doesn't exist.

## The cognitive load budget

Every abstraction you add to your platform costs developers something: learning time, mental overhead, debugging surface area. That cost is real and compounds.

The best platforms obsess over reducing cognitive load:
- Fewer concepts to learn
- Error messages that tell you what to do next, not just what went wrong
- Documentation that's findable and current
- `platform help` that actually helps

Measure your platform's complexity like you measure latency. Instrument it. When you add a new concept, ask: what are we removing to keep the budget flat?

## Closing thoughts

The best internal developer platform I've seen described itself not as a product, but as a "reliability substrate." It aimed to be load-bearing and invisible. Developers didn't think about it; they just shipped.

That's the bar. It's higher than it sounds.
