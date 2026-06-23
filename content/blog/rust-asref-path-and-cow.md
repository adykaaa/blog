---
title: "[Rust] A simple struct with one field turned into a lot of learnings"
date: 2026-06-26
description: "There are so many things happening under the hood in Rust. Let's unpack a few here."
tags: ["rust", "traits", "&str", "cow"]
draft: false
---

For a side project I decided I'm going to start implementing my own logging system (`qwiklog`). The goal of this is going to be to learn more about
Rust internals, as well as to learn about scalable logging architectures in general. I'm hoping to have more series on my blog where I cover a few areas of the project. Stay tuned!

## The Collector struct and the directory path

A log agent does multiple things, and is way out of scope for this quick blog post. For this one though, let's imagine we have a
Collector. This collector iterates over a directory (recursively), and collects all of the log file names, pretty simple.

```rust
/// A Collector collects all the log files from a given directory.
pub struct Collector {
    /// The directory path to recursively collect the .log files from.
    /// But what should be the type of the directory_path here?
    directory_path: ????,
}
```

Here I already was greeted by multiple choices. What should the directory path be -- rather, what should be the _type_ of `directory_path`? Let's see a few options.

### &str

We could go with a `&str` which is a reference to a string slice. What this means is that in Rust if we write

```rust
let thing = "Hello world!";
```

the type of `thing` is going to be `&str` -- so a _reference_ to a string slice. The `&str` only contains a pointer to some **bytes** (the actual characters), and a **length** (the length of said bytes).
This is pretty cool because the size of this is only going to be (on a typical 64-bit machine anyways) **16 bytes**, regardless of the actual data it holds.
I immediately had **two** follow up questions that needed to be answered. If I do this then:

```rust
pub struct Collector {
    /// This code is actually not correct, and we'll see why.
    directory_path: &str
}
```

and `&str` is a **reference** to a string slice, if I end up initializing my struct like so:

```rust
let c = Collector { directory_path: "/var/log/pods/" }
```

where is the **actual** string that I'm referencing? The type of `directory_path` is `&str` not a `str`! Do I have to pre-create this "`/var/log/pods/`" string somewhere, and then point the field to it?
As it turns out, the **lifetime annotated** type of `thing` from earlier is:

```rust
let thing: &'static str = "Hello world!";
```

so we can read this as "a reference to a string slice that lives until the end of our program". That's cool but how is my question answered -- WHERE IS THE DATA???
As it turns out, string literals like `"Hello world!"` have the lifetime `'static` for a reason. It means the string data is valid for the entire duration of the program, so it's not going to get randomly dropped. The bytes `[H][e][l][l][o] [w][o][r][l][d][!]` are embedded into the **compiled** binary, usually in a read-only/static memory section, and the `&str` value points to those bytes -- so **now** I know, when I write this single line of code, these bytes are actually allocated and I just get a fat pointer back to them! Question 1 has been answered.

Question 2 was a rather simple one, which is:

```rust
pub struct Collector {
    /// This code is actually not correct.
    directory_path: &str
    ///             ^missing lifetime specifier, expected named lifetime parameter
}
```

why is this failing with a missing lifetime parameter error? Just let me put that damn reference to a string there, save some memory, and be done with it!

Well the problem is that a reference does not own the value it points to. A `&str` is only a borrowed view. So if we store a `&str` inside a struct, the struct does not contain the actual string data, it only contains a pointer and a length.

That means Rust needs to know one very important thing:

How long is the referenced string guaranteed to live?

For example, imagine if Rust allowed this:

```rust
pub struct Collector {
    directory_path: &str,
}

fn create_collector() -> Collector {
    let path = String::from("/var/log/pods");

    Collector {
        directory_path: path.as_str(),
    }
}
```

This would be a disaster. Inside `create_collector`, we create a String called `path`. Then we store a reference to that string inside `Collector` but when the function returns, `path` is dropped which means that its heap allocation is **freed**.

So the returned `Collector` would contain a reference to memory that no longer exists:

```
Collector
    directory_path: &str
        |
        v
    "/var/log/pods"  // already dropped
```

which would lead to undefined behavior, as we would be accessing a memory location that has been freed.
So when we deal with a struct that contains a **reference**, we have to tell Rust that the struct is tied to the lifetime of the thing it references:

```rust
pub struct Collector<'a> {
    directory_path: &'a str,
}
```

This means **`Collector<'a>` may not live longer than the string slice it stores since they have the same 'a lifetimes.** -- aka. `directory_path` our struct field cannot be dropped earlier than our Collector, and vice-versa.

This is already looking confusing btw, but to add insult to injury, a simple `impl` block would look like this:

```rust
impl<'a> Collector<'a> {
    [...]
}
```

because we need to reference the lifetime(s) `'a` in these as well. Damn, all this for a struct with 1 field? No way! Let's look at other solutions.

### Using generics -> AsRef<Path>

## Closing thoughts
