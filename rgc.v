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

const bucket_count = 16

struct FDInfo {
mut:
    fd          int
    last_active i64
    is_active   bool
    is_exempt   bool
    timeout     i64
}

struct CustomResource {
    id         voidptr
    tag        string
    dispose_fn DisposeFn = unsafe { nil }
mut:
    last_active i64
    is_active   bool
    is_exempt   bool
    timeout     i64
}

@[params]
pub struct GCConfig {
pub:
    fd_limit       int = 1024
    idle_timeout   i64 = 5
    check_interval u32 = 2
}

pub struct RGCMetrics {
pub:
    active_fds       int
    active_custom    int
    total_closed_fds u64
    total_disposed   u64
}

struct FDBucket {
mut:
    mtx      sync.Mutex
    fd_table map[int]&FDInfo
}

__global (
    initialized      bool
    fd_buckets       []FDBucket
    custom_resources map[string]&CustomResource
    mtx              sync.Mutex
    global_config    GCConfig
    total_closed_fds u64
    total_disposed   u64
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

        for i in 0 .. bucket_count {
            mut bucket := &fd_buckets[i]
            bucket.mtx.lock()
            for fd, mut info in bucket.fd_table {
                if info.is_active && !info.is_exempt {
                    current_timeout := if info.timeout > 0 { info.timeout } else { config.idle_timeout }
                    if now - info.last_active > current_timeout {
                        if C.is_listening_socket(fd) == 1 {
                            info.last_active = now
                        } else {
                            info.is_active = false
                            fds_to_close << fd
                        }
                    }
                }
            }
            bucket.mtx.unlock()
        }

        for fd in fds_to_close {
            rgc_log('FD ${fd} expired! Closing now.')
            close_res := C.raw_close(fd)
            rgc_log('raw_close returned: ${close_res}')
            
            bucket_idx := fd % bucket_count
            mut bucket := &fd_buckets[bucket_idx]
            bucket.mtx.lock()
            total_closed_fds++
            bucket.mtx.unlock()
        }

        mut expired_custom := []CustomResource{}
        mtx.lock()
        mut keys_to_delete := []string{}
        for key, res in custom_resources {
            if res.is_active && !res.is_exempt {
                current_timeout := if res.timeout > 0 { res.timeout } else { config.idle_timeout }
                if now - res.last_active > current_timeout {
                    expired_custom << CustomResource{
                        id:          res.id
                        tag:         res.tag
                        dispose_fn:  res.dispose_fn
                        last_active: res.last_active
                        is_active:   res.is_active
                        is_exempt:   res.is_exempt
                        timeout:     res.timeout
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
                
                mtx.lock()
                total_disposed++
                mtx.unlock()
            }
        }
    }
}

@[export: 'track_open']
fn track_open(fd int) {
    if !initialized || fd < 0 {
        return
    }
    rgc_log('track_open called for FD ${fd}')
    bucket_idx := fd % bucket_count
    mut bucket := &fd_buckets[bucket_idx]
    bucket.mtx.lock()
    defer {
        bucket.mtx.unlock()
    }
    bucket.fd_table[fd] = &FDInfo{
        fd:          fd
        last_active: C.time(unsafe { nil })
        is_active:   true
        is_exempt:   false
        timeout:     0
    }
}

@[export: 'track_read']
fn track_read(fd int) {
    if !initialized || fd < 0 {
        return
    }
    bucket_idx := fd % bucket_count
    mut bucket := &fd_buckets[bucket_idx]
    if bucket.mtx.try_lock() {
        if fd in bucket.fd_table {
            mut info := bucket.fd_table[fd] or { 
                bucket.mtx.unlock()
                return 
            }
            if info.is_active {
                info.last_active = C.time(unsafe { nil })
            }
        }
        bucket.mtx.unlock()
    }
}

@[export: 'track_close']
fn track_close(fd int) {
    if !initialized || fd < 0 {
        return
    }
    rgc_log('track_close called for FD ${fd}')
    bucket_idx := fd % bucket_count
    mut bucket := &fd_buckets[bucket_idx]
    bucket.mtx.lock()
    defer {
        bucket.mtx.unlock()
    }
    if fd in bucket.fd_table {
        mut info := bucket.fd_table[fd] or { return }
        info.is_active = false
        info.is_exempt = false
    }
}

pub fn exempt_fd(fd int) {
    if !initialized || fd < 0 {
        return
    }
    bucket_idx := fd % bucket_count
    mut bucket := &fd_buckets[bucket_idx]
    bucket.mtx.lock()
    defer {
        bucket.mtx.unlock()
    }
    if fd in bucket.fd_table {
        mut info := bucket.fd_table[fd] or { return }
        info.is_exempt = true
    }
}

pub fn monitor_fd(fd int) {
    if !initialized || fd < 0 {
        return
    }
    bucket_idx := fd % bucket_count
    mut bucket := &fd_buckets[bucket_idx]
    bucket.mtx.lock()
    defer {
        bucket.mtx.unlock()
    }
    if fd in bucket.fd_table {
        mut info := bucket.fd_table[fd] or { return }
        info.is_exempt = false
        info.last_active = C.time(unsafe { nil })
    }
}

pub fn set_fd_timeout(fd int, timeout_sec i64) {
    if !initialized || fd < 0 {
        return
    }
    bucket_idx := fd % bucket_count
    mut bucket := &fd_buckets[bucket_idx]
    bucket.mtx.lock()
    defer {
        bucket.mtx.unlock()
    }
    if fd in bucket.fd_table {
        mut info := bucket.fd_table[fd] or { return }
        info.timeout = timeout_sec
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
        timeout:     0
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

pub fn set_timeout(id voidptr, tag string, timeout_sec i64) {
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
        res.timeout = timeout_sec
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

pub fn get_metrics() RGCMetrics {
    if !initialized {
        return RGCMetrics{}
    }
    
    mut active_fd_count := 0
    mut closed_fds := u64(0)
    for i in 0 .. bucket_count {
        mut bucket := &fd_buckets[i]
        bucket.mtx.lock()
        for _, info in bucket.fd_table {
            if info.is_active {
                active_fd_count++
            }
        }
        closed_fds += total_closed_fds
        bucket.mtx.unlock()
    }

    mtx.lock()
    mut active_custom_count := 0
    for _, res in custom_resources {
        if res.is_active {
            active_custom_count++
        }
    }
    disposed := total_disposed
    mtx.unlock()

    return RGCMetrics{
        active_fds:       active_fd_count
        active_custom:    active_custom_count
        total_closed_fds: closed_fds
        total_disposed:   disposed
    }
}

pub fn start(config GCConfig) {
    mtx.init()
    global_config = config
    custom_resources = map[string]&CustomResource{}
    
    fd_buckets = []FDBucket{len: bucket_count}
    for i in 0 .. bucket_count {
        fd_buckets[i].mtx.init()
        fd_buckets[i].fd_table = map[int]&FDInfo{}
    }
    
    track_open(0)
    track_open(1)
    track_open(2)
    exempt_fd(0)
    exempt_fd(1)
    exempt_fd(2)

    initialized = true
    spawn gc_worker(config)
}
