module rgc

import sync

#flag -I @VMODROOT/c
#flag @VMODROOT/c/hooks.c
#include "hooks.h"
#include <unistd.h>
#include <time.h>

fn C.dlsym(handle voidptr, symbol &char) voidptr
fn C.sleep(seconds u32) u32
fn C.raw_close(fd int) int
fn C.time(t voidptr) i64
fn C.is_listening_socket(fd int) int

pub type DisposeFn = fn (voidptr)

struct FDInfo {
mut:
    fd          int
    last_active i64
    is_active   bool
    is_exempt   bool
}

struct CustomResource {
    id         voidptr
    tag        string
    dispose_fn DisposeFn = unsafe { nil }
mut:
    last_active i64
    is_active   bool
    is_exempt   bool
}

@[params]
pub struct GCConfig {
pub:
    fd_limit       int = 1024
    idle_timeout   i64 = 5
    check_interval u32 = 2
}

__global (
    initialized      bool
    fd_table         []FDInfo
    custom_resources map[string]&CustomResource
    mtx              sync.Mutex
    fd_mtx           sync.Mutex
    global_config    GCConfig
)

fn rgc_log(msg string) {
    $if debug {
        println('[RGC] ' + msg)
    }
}

fn gc_worker(config GCConfig) {
    for {
        C.sleep(config.check_interval)
        now := C.time(unsafe { nil })

        mut fds_to_close := []int{}

        fd_mtx.lock()
        for i in 0 .. fd_table.len {
            if fd_table[i].is_active && !fd_table[i].is_exempt {
                if now - fd_table[i].last_active > config.idle_timeout {
                    if C.is_listening_socket(fd_table[i].fd) == 1 {
                        fd_table[i].last_active = now
                    } else {
                        fd_table[i].is_active = false
                        fds_to_close << fd_table[i].fd
                    }
                }
            }
        }
        fd_mtx.unlock()

        for fd in fds_to_close {
            rgc_log('FD ${fd} expired! Closing now.')
            close_res := C.raw_close(fd)
            rgc_log('raw_close returned: ${close_res}')
        }

        mut expired_custom := []CustomResource{}
        mtx.lock()
        mut keys_to_delete := []string{}
        for key, res in custom_resources {
            if res.is_active && !res.is_exempt {
                if now - res.last_active > config.idle_timeout {
                    expired_custom << CustomResource{
                        id:          res.id
                        tag:         res.tag
                        dispose_fn:  res.dispose_fn
                        last_active: res.last_active
                        is_active:   res.is_active
                        is_exempt:   res.is_exempt
                    }
                    keys_to_delete << key
                }
            }
        }
        for k in keys_to_delete {
            custom_resources.delete(k)
        }
        mtx.unlock()

        for res in expired_custom {
            if res.dispose_fn != unsafe { nil } {
                rgc_log('Custom resource ${res.tag} expired! Disposing.')
                res.dispose_fn(res.id)
            }
        }
    }
}

@[export: 'track_open']
fn track_open(fd int) {
    if !initialized {
        return
    }
    rgc_log('track_open called for FD ${fd}')
    fd_mtx.lock()
    defer {
        fd_mtx.unlock()
    }
    if fd >= 0 && fd < fd_table.len {
        fd_table[fd].fd = fd
        fd_table[fd].last_active = C.time(unsafe { nil })
        fd_table[fd].is_active = true
        fd_table[fd].is_exempt = false
    }
}

@[export: 'track_read']
fn track_read(fd int) {
    if !initialized {
        return
    }
    fd_mtx.lock()
    defer {
        fd_mtx.unlock()
    }
    if fd >= 0 && fd < fd_table.len {
        if fd_table[fd].is_active {
            fd_table[fd].last_active = C.time(unsafe { nil })
        }
    }
}

@[export: 'track_close']
fn track_close(fd int) {
    if !initialized {
        return
    }
    rgc_log('track_close called for FD ${fd}')
    fd_mtx.lock()
    defer {
        fd_mtx.unlock()
    }
    if fd >= 0 && fd < fd_table.len {
        fd_table[fd].is_active = false
        fd_table[fd].is_exempt = false
    }
}

pub fn exempt_fd(fd int) {
    if !initialized {
        return
    }
    fd_mtx.lock()
    defer {
        fd_mtx.unlock()
    }
    if fd >= 0 && fd < fd_table.len {
        fd_table[fd].is_exempt = true
    }
}

pub fn monitor_fd(fd int) {
    if !initialized {
        return
    }
    fd_mtx.lock()
    defer {
        fd_mtx.unlock()
    }
    if fd >= 0 && fd < fd_table.len {
        fd_table[fd].is_exempt = false
        fd_table[fd].last_active = C.time(unsafe { nil })
    }
}

pub fn track(id voidptr, tag string, dispose DisposeFn) {
    if !initialized {
        return
    }
    mtx.lock()
    defer {
        mtx.unlock()
    }
    key := '${tag}:${id}'
    custom_resources[key] = &CustomResource{
        id:          id
        tag:         tag
        dispose_fn:  dispose
        last_active: C.time(unsafe { nil })
        is_active:   true
        is_exempt:   false
    }
}

pub fn touch(id voidptr, tag string) {
    if !initialized {
        return
    }
    mtx.lock()
    defer {
        mtx.unlock()
    }
    key := '${tag}:${id}'
    if key in custom_resources {
        mut res := custom_resources[key] or { return }
        res.last_active = C.time(unsafe { nil })
    }
}

pub fn exempt(id voidptr, tag string) {
    if !initialized {
        return
    }
    mtx.lock()
    defer {
        mtx.unlock()
    }
    key := '${tag}:${id}'
    if key in custom_resources {
        mut res := custom_resources[key] or { return }
        res.is_exempt = true
    }
}

pub fn monitor(id voidptr, tag string) {
    if !initialized {
        return
    }
    mtx.lock()
    defer {
        mtx.unlock()
    }
    key := '${tag}:${id}'
    if key in custom_resources {
        mut res := custom_resources[key] or { return }
        res.is_exempt = false
        res.last_active = C.time(unsafe { nil })
    }
}

pub fn release(id voidptr, tag string) bool {
    if !initialized {
        return false
    }
    mtx.lock()
    defer {
        mtx.unlock()
    }
    key := '${tag}:${id}'
    if key in custom_resources {
        custom_resources.delete(key)
        return true
    }
    return false
}

pub fn start(config GCConfig) {
    mtx.init()
    fd_mtx.init()
    global_config = config
    custom_resources = map[string]&CustomResource{}
    fd_table = []FDInfo{len: config.fd_limit}
    if fd_table.len > 2 {
        fd_table[0].is_exempt = true
        fd_table[1].is_exempt = true
        fd_table[2].is_exempt = true
    }
    initialized = true
    spawn gc_worker(config)
}