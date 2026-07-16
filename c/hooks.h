#ifndef HOOKS_H
#define HOOKS_H

#include <sys/types.h>
#include <sys/socket.h>

void track_open(int fd);
void track_read(int fd);
void track_close(int fd);
int raw_close(int fd);
int is_listening_socket(int fd);

#endif