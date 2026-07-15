# RGC (Resource Garbage Collector)

RGC is a lightweight, concurrent resource garbage collector for V. It actively monitors system resource inactivity in a background scavenger thread and automatically reclaims leaked file descriptors, network sockets, and user-defined custom resources (such as memory mappings or database connections).

## Capabilities

- **Automatic OS Interception:** Overrides POSIX system calls (`open`, `read`, `write`, `close`, `socket`) to track file and network descriptor activity.
- **Explicit Custom Tracking:** Exposes a generic API for registering arbitrary pointers with custom cleanup callbacks.
- **Bionic libc Compatibility:** Disables Android process-wide `fdsan` error validation dynamically during startup to prevent dynamic-linking crashes.
- **Bootstrapping Protection:** Implements a recursion-safe resolver with raw assembly `syscall()` fallbacks to prevent linker lock-ups during startup symbol resolution.
- **Non-Blocking Callbacks:** Implements lock-release patterns to execute user-defined cleanup callbacks outside the internal mutex regions, eliminating thread deadlocks.

---

## Installation

Install RGC directly from GitHub using the V package manager:

```bash
v install --git https://github.com/tailsmails/rgc
```

---

## Usage

### Standard Usage (After Installation)

If you installed the package globally via `v install`, you can import it in any V file immediately without any directory setup:

```v
import rgc
import os
import time

fn free_mmap(addr voidptr) {
    println('Disposing address: ${addr}')
}

fn main() {
    rgc.start()

    mut f := os.create('leaked_file.txt') or { panic(err) }
    println('App: File created with FD ${f.fd}')

    mock_ptr := voidptr(0xdeadbeef)
    rgc.track(mock_ptr, 'mmap', free_mmap)
    println('App: Registered custom resource at ${mock_ptr}')

    time.sleep(10 * time.second)
}
```

### Local Setup (Without Installation)

If you prefer to include RGC directly within your project without installing it globally, organize your directory structure as follows:

```text
├── main.v
└── rgc/
    ├── v.mod
    ├── rgc.v
    └── c/
        ├── hooks.h
        └── hooks.c
```

---

## Compilation

To compile your application, enable global variables during compilation:

```bash
v -enable-globals main.v
./main
```

---

## Technical Implementation Details

- **Concurrency Safeness:** The scavenger loop evaluates idle intervals concurrently. When a custom resource times out, VGC copies the object state, purges the reference from the map, unlocks the mutex, and executes the user callback. This prevents self-deadlocks if the callback invokes tracked I/O operations (such as `println` or file writes).
- **Symbol Interception:** Hooks are statically linked into the main binary. A static C constructor dynamically queries the platform's `libc.so` (using absolute paths `/system/lib64/libc.so` or `/system/lib/libc.so` if `RTLD_DEFAULT` is restricted) to call `android_fdsan_set_error_level` and set it to `DISABLED` on Android.
- **Raw System Transitions:** Critical timing evaluations utilize direct C `C.time` pointers instead of high-level runtime abstractions to prevent indirect filesystem/timezone lookups from triggering nested I/O calls.

---

## License
![License](https://img.shields.io/badge/License-MIT-black.svg)
