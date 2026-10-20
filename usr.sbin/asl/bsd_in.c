/*
 * Copyright (c) 2004-2011 Apple Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 * 
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */

#include <TargetConditionals.h>

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/fcntl.h>
#include <sys/un.h>
#include <sys/uio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include "daemon.h"

#define BSD_SOCKET_NAME "BSDSystemLogger"
#define MY_ID "bsd_in"
#include "asl_input.h"

/* Datagrams larger than the supported libc syslog bound are discarded. */
/* Counter storage is shared with the telemetry snapshot. */

static int sock = -1;
static dispatch_source_t in_src;
static dispatch_queue_t in_queue;

void
bsd_in_acceptmsg(int fd)
{
	ssize_t n;
	char line[ASL_SOCKET_MAX + 1];
	asl_msg_t *m;

	n = asl_bsd_receive(fd, line, &asld_counters.bsd_in_truncated);
	if (n <= 0) return;

	m = asl_input_parse(line, n, NULL, SOURCE_BSD_SOCKET);
	process_message(m, SOURCE_BSD_SOCKET);
}

/* The pidfile lifetime lock is already held on the system path. */
static int
bind_log_socket(const char *path, int system_socket)
{
 struct sockaddr_un address;
 struct stat st;
 int fd, probe;
 memset(&address, 0, sizeof(address));
 address.sun_family = AF_UNIX;
 if (strlcpy(address.sun_path, path, sizeof(address.sun_path)) >= sizeof(address.sun_path)) { errno = ENAMETOOLONG; return -1; }
 address.sun_len = SUN_LEN(&address);
 if (system_socket && lstat(path, &st) == 0) {
  if (!S_ISSOCK(st.st_mode)) { errno = EEXIST; return -1; }
  probe = socket(AF_UNIX, SOCK_DGRAM, 0);
  if (probe < 0) return -1;
  int live = connect(probe, (struct sockaddr *)&address, address.sun_len);
  int error = errno;
  close(probe);
  if (live == 0) { errno = EADDRINUSE; return -1; }
  if (error != ECONNREFUSED && error != ENOENT) { errno = error; return -1; }
  if (unlink(path) != 0 && errno != ENOENT) return -1;
 }
 fd = socket(AF_UNIX, SOCK_DGRAM, 0);
 if (fd < 0) return -1;
 if (bind(fd, (struct sockaddr *)&address, address.sun_len) != 0 || chmod(path, system_socket ? 0666 : 0600) != 0) goto fail;
 if (system_socket) {
  char target[sizeof(address.sun_path)];
  ssize_t n = readlink("/dev/log", target, sizeof(target));
  if (n < 0 || (size_t)n != strlen(path) || memcmp(target, path, n) != 0) {
   if (lstat("/dev/log", &st) == 0) {
    if (!S_ISLNK(st.st_mode)) { errno = EEXIST; goto fail; }
    if (unlink("/dev/log") != 0) goto fail;
   } else if (errno != ENOENT) goto fail;
   if (symlink(path, "/dev/log") != 0) goto fail;
  }
 }
 return fd;
fail:
 { int error = errno; close(fd); errno = error; return -1; }
}

int
bsd_in_init()
{
	int rbufsize;
	int len;
	launch_data_t sockets_dict, fd_array, fd_dict;
	static dispatch_once_t once;

#if TARGET_IPHONE_SIMULATOR
	const char *_PATH_SYSLOG_IN = getenv("IOS_SIMULATOR_SYSLOG_SOCKET");
#endif

	dispatch_once(&once, ^{
		in_queue = dispatch_queue_create(MY_ID, NULL);
	});

	asldebug("%s: init\n", MY_ID);
	if (sock >= 0) return -1;

 if (global.socket_path) {
  sock = bind_log_socket(global.socket_path, 0);
 } else {
  /* Until fileports exist, launchd may return the Mach service only. */
  sockets_dict = global.launch_dict ? launch_data_dict_lookup(global.launch_dict, LAUNCH_JOBKEY_SOCKETS) : NULL;
  fd_array = sockets_dict ? launch_data_dict_lookup(sockets_dict, BSD_SOCKET_NAME) : NULL;
  fd_dict = (fd_array && launch_data_array_get_count(fd_array) > 0) ? launch_data_array_get_index(fd_array, 0) : NULL;
  sock = fd_dict ? launch_data_get_fd(fd_dict) : -1;
  if (sock < 0) sock = bind_log_socket(_PATH_SYSLOG_IN, 1);
 }
 if (sock < 0) {
  fprintf(stderr, "asld: log socket: %s\n", strerror(errno));
  return -1;
 }

	rbufsize = 128 * 1024;
	len = sizeof(rbufsize);

	if (setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &rbufsize, len) < 0)
	{
		asldebug("%s: couldn't set receive buffer size for socket %d (%s): %s\n", MY_ID, sock, _PATH_SYSLOG_IN, strerror(errno));
		close(sock);
		sock = -1;
		return -1;
	}

	if (fcntl(sock, F_SETFL, O_NONBLOCK) < 0)
	{
		asldebug("%s: couldn't set O_NONBLOCK for socket %d (%s): %s\n", MY_ID, sock, _PATH_SYSLOG_IN, strerror(errno));
		close(sock);
		sock = -1;
		return -1;
	}

	in_src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)sock, 0, in_queue);
	dispatch_source_set_event_handler(in_src, ^{ bsd_in_acceptmsg(sock); });

	dispatch_resume(in_src);
	return 0;
}

int
bsd_in_close(void)
{
	if (sock < 0) return 1;

	dispatch_source_cancel(in_src);
	dispatch_release(in_src);
	in_src = NULL;

	close(sock);
	sock = -1;

	return 0;
}

int
bsd_in_reset(void)
{
	return 0;
}
