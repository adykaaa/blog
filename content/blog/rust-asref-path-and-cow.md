---
title: "Rust: Choosing a Path Type for a Collector"
date: 2026-06-23
description: "A small Collector struct is a practical tour of string literals, lifetimes, PathBuf, AsRef<Path>, and Cow."
tags: ["rust", "traits", "paths", "cow"]
draft: false
---

For a side project, I am building a small logging system called `qwiklog`. The project is an excuse to learn more about Rust internals and scalable logging architectures. This is the first of what I hope will become a series of short notes from that work.

## The `Collector` and its directory path

A log agent does much more than walk a directory, but that is enough for this example. Suppose a `Collector` recursively finds log files under one directory.

```rust
/// Collects log files from a directory.
pub struct Collector {
    // What should this field's type be?
    directory_path: ????,
}
```

The obvious first candidate is `&str`:

```rust
let path = "/var/log/pods";
```

Here, `path` has type `&'static str`: a borrowed string slice whose data is valid for the entire program. The literal's bytes are embedded in the compiled binary, usually in read-only memory. A `&str` is a *fat pointer* containing a pointer to those UTF-8 bytes and their length; it does not own or allocate the string.

That makes literals convenient, but it does not make `&str` a good default field type:

```rust
pub struct Collector {
    directory_path: &str,
}
```

This does not compile because the reference needs an explicit lifetime. More importantly, the compiler needs proof that the referenced string outlives the `Collector`.

```rust
pub struct Collector<'a> {
    directory_path: &'a str,
}

fn create_collector() -> Collector<'static> {
    Collector {
        directory_path: "/var/log/pods",
    }
}
```

The `'static` version is fine because the literal never disappears. A borrowed `String` created inside a function is not:

```rust,compile_fail
fn create_collector() -> Collector<'static> {
    let path = String::from("/var/log/pods");

    Collector {
        directory_path: path.as_str(),
    }
}
```

`path` is dropped when the function returns, so returning a reference to it would leave `Collector` pointing at freed memory. Rust rejects that state before the program can run.

Borrowing can be exactly right when `Collector` is a short-lived view over data owned elsewhere. It does, however, tie the struct and every relevant `impl` to a lifetime:

```rust
impl<'a> Collector<'a> {
    // Methods go here.
}
```

For a component that owns its configuration, that complexity buys little.

## Use path types for paths

`str` and `String` represent UTF-8 text. Filesystem paths are not necessarily UTF-8, so Rust exposes `Path` and `PathBuf` for path data. `Path` is the borrowed counterpart; `PathBuf` owns its contents.

An owning collector is therefore simple and accurate:

```rust
use std::path::PathBuf;

pub struct Collector {
    directory_path: PathBuf,
}
```

Now `Collector` owns the path, has no lifetime parameter, and can safely outlive the caller that created it.

The constructor should accept the broadest useful input type and convert it at the boundary:

```rust
use std::path::{Path, PathBuf};

impl Collector {
    pub fn new(path: impl AsRef<Path>) -> Self {
        Self {
            directory_path: path.as_ref().to_path_buf(),
        }
    }
}
```

`AsRef<Path>` accepts common path-like values—such as `&str`, `String`, `&Path`, and `PathBuf`—without forcing callers to allocate a `PathBuf` first. The collector converts once and stores the owned representation it needs.

```rust
let from_literal = Collector::new("/var/log/pods");
let from_owned = Collector::new(PathBuf::from("/var/log/pods"));
```

## Where `Cow` fits

`Cow<'a, Path>` means *clone on write*. It can hold either a borrowed `&'a Path` or an owned `PathBuf`, cloning only if a later operation needs ownership or mutation.

```rust
use std::borrow::Cow;
use std::path::Path;

fn normalize_path<'a>(path: &'a Path) -> Cow<'a, Path> {
    if path.is_absolute() {
        Cow::Borrowed(path)
    } else {
        Cow::Owned(Path::new("/var/log").join(path))
    }
}
```

This is useful in APIs that sometimes transform their input and sometimes return it unchanged. It is usually not the best storage type for `Collector`: it keeps the lifetime complexity of borrowing while making ownership conditional. Prefer `PathBuf` when the struct should own its configuration, and use `Cow` when avoiding an unnecessary clone is part of the API's value.

## Takeaway

Choose the type based on ownership and domain semantics:

- Use `&str` for a borrowed UTF-8 string when the caller owns the data and the lifetime relationship is useful.
- Use `String` when you need to own UTF-8 text.
- Use `Path` and `PathBuf` for filesystem paths; store `PathBuf` when the struct owns the path.
- Accept `impl AsRef<Path>` at API boundaries for ergonomic callers.
- Use `Cow<'_, Path>` only when borrowed-or-owned behavior avoids a meaningful allocation.

For this collector, one owned `PathBuf` is the clearest answer.
