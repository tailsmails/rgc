import rgc
import os
import time

fn mock_unmap(addr voidptr) {
    println('[RGC] Safe cleanup: unmapping custom resource at ${addr}')
}

fn main() {
    rgc.start()

    mut f := os.create('leaked_file.txt') or { panic(err) }
    println('App: File created with FD ${f.fd}')

    mock_mmap_ptr := voidptr(0xdeadbeef)
    rgc.track(mock_mmap_ptr, 'mmap', mock_unmap)
    println('App: Registered custom mmap resource at ${mock_mmap_ptr}')

    println('App: Going into sleep. RGC will sweep both FD ${f.fd} and mmap in 5 seconds...')
    time.sleep(10 * time.second)
    println('App: Terminated.')
}
