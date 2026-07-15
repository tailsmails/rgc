#define _GNU_SOURCE
#include <fcntl.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <sys/syscall.h>
#include <sys/socket.h>
#include "hooks.h"

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

static int (*orig_open)(const char *, int, ...) = NULL;
static ssize_t (*orig_read)(int, void *, size_t) = NULL;
static ssize_t (*orig_write)(int, const void *, size_t) = NULL;
static int (*orig_close)(int) = NULL;
static int (*orig_socket)(int, int, int) = NULL;
static int (*orig_accept)(int, struct sockaddr *, socklen_t *) = NULL;
static int (*orig_accept4)(int, struct sockaddr *, socklen_t *, int) = NULL;
static ssize_t (*orig_recv)(int, void *, size_t, int) = NULL;
static ssize_t (*orig_send)(int, const void *, size_t, int) = NULL;
static ssize_t (*orig_recvfrom)(int, void *, size_t, int, struct sockaddr *, socklen_t *) = NULL;
static ssize_t (*orig_sendto)(int, const void *, size_t, int, const struct sockaddr *, socklen_t) = NULL;

static int resolving = 0;

int is_listening_socket(int fd) {
    int val = 0;
    socklen_t len = sizeof(val);
    if (getsockopt(fd, SOL_SOCKET, SO_ACCEPTCONN, &val, &len) == 0) {
        return val != 0;
    }
    return 0;
}

__attribute__((constructor)) void init_fdsan_bypass() {
    void *libc = dlopen("/system/lib64/libc.so", RTLD_LAZY);
    if (!libc) { libc = dlopen("/system/lib/libc.so", RTLD_LAZY); }
    if (!libc) { libc = dlopen("libc.so", RTLD_LAZY); }

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
    if (orig_open && orig_read && orig_write && orig_close && orig_socket &&
        orig_accept && orig_accept4 && orig_recv && orig_send && orig_recvfrom && orig_sendto) return;
    resolving = 1;

    void *p_open = dlsym(RTLD_NEXT, "open");
    void *p_read = dlsym(RTLD_NEXT, "read");
    void *p_write = dlsym(RTLD_NEXT, "write");
    void *p_close = dlsym(RTLD_NEXT, "close");
    void *p_socket = dlsym(RTLD_NEXT, "socket");
    void *p_accept = dlsym(RTLD_NEXT, "accept");
    void *p_accept4 = dlsym(RTLD_NEXT, "accept4");
    void *p_recv = dlsym(RTLD_NEXT, "recv");
    void *p_send = dlsym(RTLD_NEXT, "send");
    void *p_recvfrom = dlsym(RTLD_NEXT, "recvfrom");
    void *p_sendto = dlsym(RTLD_NEXT, "sendto");

    if (p_open == (void*)open || p_open == NULL) {
        void *libc = dlopen("/system/lib64/libc.so", RTLD_LAZY);
        if (!libc) { libc = dlopen("/system/lib/libc.so", RTLD_LAZY); }
        if (!libc) { libc = dlopen("libc.so", RTLD_LAZY); }
        if (libc) {
            p_open = dlsym(libc, "open");
            p_read = dlsym(libc, "read");
            p_write = dlsym(libc, "write");
            p_close = dlsym(libc, "close");
            p_socket = dlsym(libc, "socket");
            p_accept = dlsym(libc, "accept");
            p_accept4 = dlsym(libc, "accept4");
            p_recv = dlsym(libc, "recv");
            p_send = dlsym(libc, "send");
            p_recvfrom = dlsym(libc, "recvfrom");
            p_sendto = dlsym(libc, "sendto");
        }
    }

    orig_open = (int (*)(const char *, int, ...))p_open;
    orig_read = (ssize_t (*)(int, void *, size_t))p_read;
    orig_write = (ssize_t (*)(int, const void *, size_t))p_write;
    orig_close = (int (*)(int))p_close;
    orig_socket = (int (*)(int, int, int))p_socket;
    orig_accept = (int (*)(int, struct sockaddr *, socklen_t *))p_accept;
    orig_accept4 = (int (*)(int, struct sockaddr *, socklen_t *, int))p_accept4;
    orig_recv = (ssize_t (*)(int, void *, size_t, int))p_recv;
    orig_send = (ssize_t (*)(int, const void *, size_t, int))p_send;
    orig_recvfrom = (ssize_t (*)(int, void *, size_t, int, struct sockaddr *, socklen_t *))p_recvfrom;
    orig_sendto = (ssize_t (*)(int, const void *, size_t, int, const struct sockaddr *, socklen_t))p_sendto;
    resolving = 0;
}

void raw_close(int fd) { syscall(__NR_close, fd); }

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

int accept(int sockfd, struct sockaddr *addr, socklen_t *addrlen) {
    if (resolving || !orig_accept) {
        if (!orig_accept && !resolving) {
            resolve_symbols();
            if (orig_accept) return orig_accept(sockfd, addr, addrlen);
        }
        #ifdef __NR_accept
        return syscall(__NR_accept, sockfd, addr, addrlen);
        #elif defined(__NR_accept4)
        return syscall(__NR_accept4, sockfd, addr, addrlen, 0);
        #else
        return -1;
        #endif
    }

    track_read(sockfd);
    int fd = orig_accept(sockfd, addr, addrlen);
    if (fd >= 0) {
        track_open(fd);
    }
    return fd;
}

int accept4(int sockfd, struct sockaddr *addr, socklen_t *addrlen, int flags) {
    if (resolving || !orig_accept4) {
        if (!orig_accept4 && !resolving) {
            resolve_symbols();
            if (orig_accept4) return orig_accept4(sockfd, addr, addrlen, flags);
        }
        #ifdef __NR_accept4
        return syscall(__NR_accept4, sockfd, addr, addrlen, flags);
        #else
        return -1;
        #endif
    }

    track_read(sockfd);
    int fd = orig_accept4(sockfd, addr, addrlen, flags);
    if (fd >= 0) {
        track_open(fd);
    }
    return fd;
}

ssize_t recv(int sockfd, void *buf, size_t len, int flags) {
    if (resolving || !orig_recv) {
        if (!orig_recv && !resolving) {
            resolve_symbols();
            if (orig_recv) return orig_recv(sockfd, buf, len, flags);
        }
        #ifdef __NR_recvfrom
        return syscall(__NR_recvfrom, sockfd, buf, len, flags, NULL, NULL);
        #else
        return -1;
        #endif
    }

    ssize_t bytes = orig_recv(sockfd, buf, len, flags);
    track_read(sockfd);
    return bytes;
}

ssize_t send(int sockfd, const void *buf, size_t len, int flags) {
    if (resolving || !orig_send) {
        if (!orig_send && !resolving) {
            resolve_symbols();
            if (orig_send) return orig_send(sockfd, buf, len, flags);
        }
        #ifdef __NR_sendto
        return syscall(__NR_sendto, sockfd, buf, len, flags, NULL, 0);
        #else
        return -1;
        #endif
    }

    ssize_t bytes = orig_send(sockfd, buf, len, flags);
    track_read(sockfd);
    return bytes;
}

ssize_t recvfrom(int sockfd, void *buf, size_t len, int flags, struct sockaddr *src_addr, socklen_t *addrlen) {
    if (resolving || !orig_recvfrom) {
        if (!orig_recvfrom && !resolving) {
            resolve_symbols();
            if (orig_recvfrom) return orig_recvfrom(sockfd, buf, len, flags, src_addr, addrlen);
        }
        #ifdef __NR_recvfrom
        return syscall(__NR_recvfrom, sockfd, buf, len, flags, src_addr, addrlen);
        #else
        return -1;
        #endif
    }

    ssize_t bytes = orig_recvfrom(sockfd, buf, len, flags, src_addr, addrlen);
    track_read(sockfd);
    return bytes;
}

ssize_t sendto(int sockfd, const void *buf, size_t len, int flags, const struct sockaddr *dest_addr, socklen_t addrlen) {
    if (resolving || !orig_sendto) {
        if (!orig_sendto && !resolving) {
            resolve_symbols();
            if (orig_sendto) return orig_sendto(sockfd, buf, len, flags, dest_addr, addrlen);
        }
        #ifdef __NR_sendto
        return syscall(__NR_sendto, sockfd, buf, len, flags, dest_addr, addrlen);
        #else
        return -1;
        #endif
    }

    ssize_t bytes = orig_sendto(sockfd, buf, len, flags, dest_addr, addrlen);
    track_read(sockfd);
    return bytes;
}