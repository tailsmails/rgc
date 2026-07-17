# RGC (Resource Garbage Collector)

RGC is a lightweight, concurrent resource garbage collector for V. It actively monitors system resource inactivity in a background scavenger thread and automatically reclaims leaked file descriptors, network sockets, and user-defined custom resources (such as memory mappings or database connections).

## Capabilities

- **Automatic OS Interception:** Overrides POSIX system calls (`open`, `read`, `write`, `close`, `socket`) to track file and network descriptor activity.
- **Explicit Custom Tracking:** Exposes a generic API for registering arbitrary pointers with custom cleanup callbacks.
- **Manual Resource Exemption (Whitelisting):** Provides explicit `exempt_fd()` / `exempt()` and `monitor_fd()` / `monitor()` APIs to dynamically pause or resume garbage collection on highly critical resources (such as database connection pools or long-lived Keep-Alive sockets).
- **Standard I/O Protection:** Automatically shields system-level standard I/O descriptors (stdin, stdout, and stderr) from the scavenger worker to prevent application console logging or input loops from breaking due to inactivity.
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

If you installed the package globally via `v install`, you can import it in any V file. The example below demonstrates initialization with a custom configuration, default tracking, and how to programmatically exempt and re-enable resource monitoring:

```v
import rgc
import os
import time

fn free_mmap(addr voidptr) {
    println('Disposing address: ${addr}')
}

fn main() {
    rgc.start(rgc.GCConfig{
        fd_limit: 1024
        idle_timeout: 5
        check_interval: 2
    })

    mut f := os.create('leaked_file.txt') or { panic(err) }
    println('App: File created with FD ${f.fd}')

    mock_ptr := voidptr(0xdeadbeef)
    rgc.track(mock_ptr, 'mmap', free_mmap)
    println('App: Registered custom resource at ${mock_ptr}')

    rgc.exempt_fd(f.fd)
    println('App: Exempted FD ${f.fd} from garbage collection')

    time.sleep(6 * time.second)

    rgc.monitor_fd(f.fd)
    println('App: FD ${f.fd} is now back under active GC monitoring')

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

By default, RGC operates silently in production mode with zero runtime logging overhead. To compile your application with standard options:

```bash
v -enable-globals main.v
./main
```

### Debug Logging Mode

If you need to observe the internal scavenger activity, symbol hooking, and descriptor life cycle, compile your application with the debug flag (`-g` or `-cg`). 

All RGC diagnostic logs are prefixed with `[RGC]` and are entirely excluded from the final binary in production builds (when compiled without the debug flags), guaranteeing zero performance cost:

```bash
v -enable-globals -g main.v
./main
```

---

## Technical Implementation Details

- **Concurrency & Lock Isolation:** To ensure compilation safety across all major platforms and various versions of the V compiler, RGC implements a clean, dual-mutex architecture. It utilizes `fd_mtx` exclusively for file descriptor structures and `mtx` for custom resources, minimizing thread contention on performance-critical standard I/O paths.
- **FD Recycling Protection:** System-level file descriptor reuse represents a classic race condition. RGC ensures that whenever the scavenger thread reclaims an idle descriptor, state transitions (`is_active = false` and `is_exempt = false`) are executed entirely within the locked scope of `fd_mtx` *before* invoking `C.raw_close`. Any subsequent system call reuse will safely reset the tracking states.
- **Symbol Interception:** Hooks are statically linked into the main binary. A static C constructor dynamically queries the platform's `libc.so` (using absolute paths `/system/lib64/libc.so` or `/system/lib/libc.so` if `RTLD_DEFAULT` is restricted) to call `android_fdsan_set_error_level` and set it to `DISABLED` on Android.
- **Raw System Transitions:** Critical timing evaluations utilize direct C `C.time` pointers instead of high-level runtime abstractions to prevent indirect filesystem/timezone lookups from triggering nested I/O calls.

---

## Core Concepts & Architectural Design

RGC is designed around advanced systems programming paradigms to ensure that low-level resource management is both safe and developer-friendly. Below is an in-depth breakdown of the core concepts and mechanics that govern RGC's runtime behavior.

### 1. Resource Activity & The `touch` Heartbeat
At the heart of RGC is an inactivity-based garbage collector. When a custom resource is registered, RGC initiates an idle countdown. 
- To keep an active resource from being garbage collected, the developer must periodically invoke the `touch()` function. 
- The `touch()` operation acts as a heartbeat, resetting the resource's last-active timestamp to the current system time. This restarts the idle countdown from zero.
- This is particularly crucial for custom, non-descriptor resources (like memory maps, GPU contexts, or active DB connections) where the operating system does not automatically record read/write activity.

### 2. Explicit Exemption & Monitoring (Whitelisting)
Certain resources must remain open indefinitely, even if they stay inactive for long periods (e.g., database connection pools, persistent Keep-Alive sockets, or daemon listeners).
- **Exemption (`exempt` / `exempt_fd`):** This operation flags a specific resource as exempt. During the sweep cycles, the background scavenger worker completely ignores whitelisted resources, ensuring they are never closed due to idle timeout.
- **Monitoring (`monitor` / `monitor_fd`):** This reverses the exemption. Once called, the resource is placed back into the active garbage collection cycle, and its inactivity tracking resumes from that exact timestamp.

### 3. Automatic OS-Level Interception
To manage standard OS descriptors without forcing developers to manually call keep-alive heartbeats, RGC integrates low-level interception hooks.
- It overrides POSIX-compliant system calls (such as `open`, `read`, `write`, and `close`) in the C layer.
- Every time a file descriptor is accessed by the application, the underlying hook intercepts the call and silently updates the descriptor's last-active timestamp. This ensures transparent, zero-effort garbage collection for standard I/O resources.

### 4. Standard I/O Shielding
In POSIX-compliant operating systems, file descriptors `0`, `1`, and `2` represent standard input (`stdin`), standard output (`stdout`), and standard error (`stderr`), respectively.
- If these descriptors were to be closed due to a period of inactivity, the application would lose the ability to print logs to the console or receive user input, resulting in an unresponsive state.
- During initialization, RGC automatically flags these three system-critical descriptors as perpetually exempt, ensuring the application's basic console and logging infrastructure is never broken.

### 5. Bionic libc & fdsan Compatibility
Modern Android systems use Bionic libc, which features a utility called `fdsan` (File Descriptor Sanitizer). This sanitizer actively monitors the process to detect improper file descriptor usage, such as double-closes.
- Because RGC's background scavenger manages and closes file descriptors dynamically, `fdsan` might flag these background closures as anomalous, causing the Android process to terminate abruptly.
- To guarantee cross-platform compatibility, RGC checks for Android environments during initialization and dynamically adjusts the process-wide `fdsan` error level to prevent runtime validation crashes.

### 6. FD Recycling & Race Condition Prevention
Operating systems heavily recycle file descriptor IDs. Once a file is closed, its ID is quickly reassigned to the next opened file. This behavior introduces a classic systems-programming race condition:
- If the scavenger decides to close an idle descriptor (e.g., ID `10`), but another thread opens a new file and receives ID `10` right before the close occurs, the scavenger might accidentally close the newly opened, valid file.
- RGC prevents this by wrapping state transitions (`is_active = false`) and the actual close operation within a single, highly synchronized mutex block. This atomic check ensures that a descriptor cannot be reassigned or reused while the scavenger is actively processing its closure.

### 7. Lock-Release Isolation & Deadlock Prevention
A common pitfall in concurrent programming is executing arbitrary user code while holding internal synchronization locks. If a user's custom `dispose_fn` callback attempts to call RGC functions (like registering or releasing a resource) while the global mutex is locked, it will cause a permanent thread deadlock.
- RGC solves this with a two-phase cleanup pipeline. 
- In the first phase, it locks the resource table, identifies all expired custom resources, removes them from the active list, and temporarily buffers them.
- In the second phase, it completely releases the global mutex *before* iterating over the expired buffer to execute the user's custom cleanup callbacks. This design guarantees thread-safety and eliminates the possibility of deadlocks.

---

### Timeout Management

RGC allows you to maintain control over the lifetimes of your sockets, files, and custom resources. By default, resources are garbage-collected based on a global idle timeout, but you can also configure fine-grained, individual timeouts for specific file descriptors or custom resources.

#### 1. Global Idle Timeout
During initialization, you can define a global `idle_timeout` (in seconds) via `GCConfig`. If a resource or socket remains inactive (no read operations recorded) for longer than this duration, it is automatically closed or disposed.

```v
import rgc

fn main() {
    rgc.start(rgc.GCConfig{
        idle_timeout: 10 // Global timeout of 10 seconds
        check_interval: 2
    })
}
```

#### 2. Custom Timeout for File Descriptors (FDs)
Not all connections have the same lifecycle. For example, a persistent database file or a long-lived keep-alive socket might need to stay open much longer than a transient HTTP connection. You can override the global timeout for individual file descriptors using `set_fd_timeout`:

```v
mut f := os.create('persistent_log.log') or { panic(err) }

// Keep this file descriptor open for up to 1 hour (3600 seconds) of inactivity
rgc.set_fd_timeout(f.fd, 3600)
```

#### 3. Custom Timeout for Custom Resources
Similarly, custom resources (such as memory pointers, database connection handles, or third-party handles) can be assigned dedicated lease times using `set_timeout`. This overrides the default global timeout for that specific resource:

```v
mock_ptr := voidptr(0xdeadbeef)
rgc.track(mock_ptr, 'db_conn', close_db_connection)

// This connection handle will only expire after 120 seconds of inactivity (no `touch` calls)
rgc.set_timeout(mock_ptr, 'db_conn', 120)
```

#### Timeout API Reference

| Function | Description |
|---|---|
| `rgc.set_fd_timeout(fd int, timeout_sec i64)` | Overrides the global timeout for a specific file descriptor. |
| `rgc.set_timeout(id voidptr, tag string, timeout_sec i64)` | Overrides the global timeout for a specific registered custom resource. |
| `rgc.exempt_fd(fd int)` | Completely exempts a file descriptor from being closed, regardless of inactivity. |
| `rgc.exempt(id voidptr, tag string)` | Completely exempts a custom resource from being disposed, regardless of inactivity. |

---

## License
![License](https://img.shields.io/badge/License-MIT-black.svg)
