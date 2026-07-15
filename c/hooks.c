#define _GNU_SOURCE
#include <fcntl.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <sys/syscall.h>

#ifndef RTLD_NEXT
#define RTLD_NEXT ((void *)-1l)
#endif

#ifndef AT_FDCWD
#define AT_FDCWD -100
#endif

typedef enum {
    ANDROID_FDSAN_ERROR_LEVEL_DISABLED,
    ANDROID_FDSAN_ERROR_LEVEL_WARN_ONCE,
    ANDROID_FDSAN_ERROR_LEVEL_WARN_ALWAYS,
    ANDROID_FDSAN_ERROR_LEVEL_FATAL,
} fdsan_level_t;

typedef fdsan_level_t (*set_error_level_t)(fdsan_level_t);

void track_open(int fd);
void track_read(int fd);
void track_close(int fd);

static int (*orig_open)(const char *, int, ...) = NULL;
static ssize_t (*orig_read)(int, void *, size_t) = NULL;
static ssize_t (*orig_write)(int, const void *, size_t) = NULL;
static int (*orig_close)(int) = NULL;
static int (*orig_socket)(int, int, int) = NULL;
static int resolving = 0;

int open(const char *pathname, int flags, ...);

__attribute__((constructor)) void init_fdsan_bypass() {
    void *libc = dlopen("/system/lib64/libc.so", RTLD_LAZY);
    if (!libc) {
        libc = dlopen("/system/lib/libc.so", RTLD_LAZY);
    }
    if (!libc) {
        libc = dlopen("libc.so", RTLD_LAZY);
    }

    set_error_level_t set_level = NULL;
    if (libc) {
        set_level = (set_error_level_t)dlsym(libc, "android_fdsan_set_error_level");
    }
    if (!set_level) {
        set_level = (set_error_level_t)dlsym(RTLD_DEFAULT, "android_fdsan_set_error_level");
    }

    if (set_level) {
        set_level(ANDROID_FDSAN_ERROR_LEVEL_DISABLED);
    }
}

static void resolve_symbols() {
    if (orig_open && orig_read && orig_write && orig_close && orig_socket) return;
    resolving = 1;

    void *p_open = dlsym(RTLD_NEXT, "open");
    void *p_read = dlsym(RTLD_NEXT, "read");
    void *p_write = dlsym(RTLD_NEXT, "write");
    void *p_close = dlsym(RTLD_NEXT, "close");
    void *p_socket = dlsym(RTLD_NEXT, "socket");

    if (p_open == (void*)open || p_open == NULL) {
        void *libc = dlopen("/system/lib64/libc.so", RTLD_LAZY);
        if (!libc) {
            libc = dlopen("/system/lib/libc.so", RTLD_LAZY);
        }
        if (!libc) {
            libc = dlopen("libc.so", RTLD_LAZY);
        }
        if (libc) {
            p_open = dlsym(libc, "open");
            p_read = dlsym(libc, "read");
            p_write = dlsym(libc, "write");
            p_close = dlsym(libc, "close");
            p_socket = dlsym(libc, "socket");
        }
    }

    orig_open = (int (*)(const char *, int, ...))p_open;
    orig_read = (ssize_t (*)(int, void *, size_t))p_read;
    orig_write = (ssize_t (*)(int, const void *, size_t))p_write;
    orig_close = (int (*)(int))p_close;
    orig_socket = (int (*)(int, int, int))p_socket;
    resolving = 0;
}

void raw_close(int fd) {
    syscall(__NR_close, fd);
}

int open(const char *pathname, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, mode_t);
        va_end(args);
    }

    if (resolving || !orig_open) {
        if (!orig_open && !resolving) {
            resolve_symbols();
            return orig_open(pathname, flags, mode);
        }
        #ifdef __NR_openat
        return syscall(__NR_openat, AT_FDCWD, pathname, flags, mode);
        #else
        return syscall(__NR_open, pathname, flags, mode);
        #endif
    }

    int fd = orig_open(pathname, flags, mode);
    track_open(fd);
    return fd;
}

ssize_t read(int fd, void *buf, size_t count) {
    if (resolving || !orig_read) {
        if (!orig_read && !resolving) {
            resolve_symbols();
            return orig_read(fd, buf, count);
        }
        return syscall(__NR_read, fd, buf, count);
    }

    ssize_t bytes = orig_read(fd, buf, count);
    track_read(fd);
    return bytes;
}

ssize_t write(int fd, const void *buf, size_t count) {
    if (resolving || !orig_write) {
        if (!orig_write && !resolving) {
            resolve_symbols();
            return orig_write(fd, buf, count);
        }
        return syscall(__NR_write, fd, buf, count);
    }

    ssize_t bytes = orig_write(fd, buf, count);
    track_read(fd);
    return bytes;
}

int close(int fd) {
    if (resolving || !orig_close) {
        if (!orig_close && !resolving) {
            resolve_symbols();
            return orig_close(fd);
        }
        return syscall(__NR_close, fd);
    }

    track_close(fd);
    return orig_close(fd);
}

int socket(int domain, int type, int protocol) {
    if (resolving || !orig_socket) {
        if (!orig_socket && !resolving) {
            resolve_symbols();
            return orig_socket(domain, type, protocol);
        }
        return syscall(__NR_socket, domain, type, protocol);
    }

    int fd = orig_socket(domain, type, protocol);
    track_open(fd);
    return fd;
}
