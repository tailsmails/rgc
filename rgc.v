module rgc

import sync

#flag -I @VMODROOT/c
#flag @VMODROOT/c/hooks.c
#include "hooks.h"
#include <pthread.h>
#include <unistd.h>
#include <time.h>

fn C.dlsym(handle voidptr, symbol &char) voidptr

@[typedef]
struct C.pthread_t {}

fn C.pthread_create(thread &C.pthread_t, attr voidptr, start_routine fn (voidptr) voidptr, arg voidptr) int
fn C.pthread_detach(thread C.pthread_t) int
fn C.sleep(seconds u32) u32
fn C.raw_close(fd int)
fn C.time(t voidptr) i64
fn C.is_listening_socket(fd int) int

pub type DisposeFn = fn (voidptr)

struct FDInfo {
mut:
    fd          int
    last_active i64
    is_active   bool
}

struct CustomResource {
    id         voidptr
    tag        string
    dispose_fn DisposeFn = unsafe { nil }
mut:
    last_active i64
    is_active   bool
}

__global (
    fd_table         [1024]FDInfo
    custom_resources map[string]&CustomResource
    mtx              sync.Mutex
)

fn gc_worker(arg voidptr) voidptr {
    _ = arg
    for {
        C.sleep(2)
        now := C.time(unsafe { nil })
        mut expired_custom := []CustomResource{}

        mtx.lock()
        for i in 0 .. 1024 {
            if fd_table[i].is_active {
                if now - fd_table[i].last_active > 5 {
                    if C.is_listening_socket(fd_table[i].fd) == 1 {
                        fd_table[i].last_active = now
                    } else {
                        C.raw_close(fd_table[i].fd)
                        fd_table[i].is_active = false
                    }
                }
            }
        }

        mut keys_to_delete := []string{}
        for key, res in custom_resources {
            if res.is_active {
                if now - res.last_active > 5 {
                    expired_custom << CustomResource{
                        id:          res.id
                        tag:         res.tag
                        dispose_fn:  res.dispose_fn
                        last_active: res.last_active
                        is_active:   res.is_active
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
            res.dispose_fn(res.id)
        }
    }
    return unsafe { nil }
}

@[export: 'track_open']
fn track_open(fd int) {
    if fd >= 0 && fd < 1024 {
        mtx.lock()
        fd_table[fd].fd = fd
        fd_table[fd].last_active = C.time(unsafe { nil })
        fd_table[fd].is_active = true
        mtx.unlock()
    }
}

@[export: 'track_read']
fn track_read(fd int) {
    if fd >= 0 && fd < 1024 {
        mtx.lock()
        if fd_table[fd].is_active {
            fd_table[fd].last_active = C.time(unsafe { nil })
        }
        mtx.unlock()
    }
}

@[export: 'track_close']
fn track_close(fd int) {
    if fd >= 0 && fd < 1024 {
        mtx.lock()
        fd_table[fd].is_active = false
        mtx.unlock()
    }
}

pub fn track(id voidptr, tag string, dispose DisposeFn) {
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
    }
}

pub fn touch(id voidptr, tag string) {
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

pub fn release(id voidptr, tag string) {
    mtx.lock()
    defer {
        mtx.unlock()
    }
    key := '${tag}:${id}'
    if key in custom_resources {
        custom_resources.delete(key)
    }
}

pub fn start() {
    mtx.init()
    custom_resources = map[string]&CustomResource{}
    tid := C.pthread_t{}
    C.pthread_create(&tid, unsafe { nil }, gc_worker, unsafe { nil })
    C.pthread_detach(tid)
}