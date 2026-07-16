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

## License
![License](https://img.shields.io/badge/License-MIT-black.svg)