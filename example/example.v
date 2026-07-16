import rgc
import os
import time

fn C.write(fd int, buf voidptr, count usize) int

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

    res := C.write(f.fd, 'this should fail'.str, 16)
    if res < 0 {
        println('Verified: FD 3 was successfully closed by RGC!')
    } else {
        println('Oops! raw write succeeded unexpectedly! Size: ${res}')
    }
}