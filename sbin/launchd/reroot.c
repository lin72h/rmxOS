/*-
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Copyright (c) 1991, 1993
 *	The Regents of the University of California.  All rights reserved.
 *
 * This code is derived from software contributed to Berkeley by
 * Donn Seeley at Berkeley Software Design, Inc.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. Neither the name of the University nor the names of its contributors
 *    may be used to endorse or promote products derived from this software
 *    without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

/* Reroot handoff follows FreeBSD sbin/init/init.c's RESCUE path. */
#include <sys/types.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <errno.h>
#include <fcntl.h>
#include <libutil.h>
#include <mntopts.h>
#include <stdlib.h>
#include <unistd.h>
#include "launchd.h"

int
launchd_reroot(void)
{
	struct stat sb;
	struct iovec *iov = NULL;
	char *buf = NULL;
	size_t done;
	ssize_t count;
	int fd = -1, saved_errno, iovlen = 0;

	/* The static rescue init can survive unmounting the old root. */
	fd = open("/rescue/init", O_RDONLY | O_CLOEXEC);
	if (fd == -1 || fstat(fd, &sb) == -1)
		goto failed;
	if (!S_ISREG(sb.st_mode) || sb.st_size <= 0) {
		errno = EINVAL;
		goto failed;
	}
	buf = malloc(sb.st_size);
	if (buf == NULL)
		goto failed;
	for (done = 0; done < (size_t)sb.st_size;) {
		count = read(fd, buf + done, sb.st_size - done);
		if (count == -1 && errno == EINTR)
			continue;
		if (count <= 0) {
			if (count == 0)
				errno = EIO;
			goto failed;
		}
		done += count;
	}
	if (close(fd) == -1) {
		fd = -1;
		goto failed;
	}
	fd = -1;
	if (mkdir("/dev/reroot", 0700) == -1 && errno != EEXIST)
		goto failed;
	build_iovec(&iov, &iovlen, "fstype", __DECONST(void *, "tmpfs"), (size_t)-1);
	build_iovec(&iov, &iovlen, "fspath", __DECONST(void *, "/dev/reroot"), (size_t)-1);
	if (nmount(iov, iovlen, 0) == -1)
		goto failed;
	fd = open("/dev/reroot/init", O_WRONLY | O_CREAT | O_EXCL, 0700);
	if (fd == -1)
		goto failed;
	for (done = 0; done < (size_t)sb.st_size;) {
		count = write(fd, buf + done, sb.st_size - done);
		if (count == -1 && errno == EINTR)
			continue;
		if (count <= 0) {
			if (count == 0)
				errno = EIO;
			goto failed;
		}
		done += count;
	}
	if (close(fd) == -1) {
		fd = -1;
		goto failed;
	}
	fd = -1;
	free(buf);
	buf = NULL;
	free_iovec(&iov, &iovlen);
	iov = NULL;
	/* Rescue init performs RB_REROOT and selects the new root's init_path. */
	execl("/dev/reroot/init", "/dev/reroot/init", "-r", NULL);
failed:
	saved_errno = errno;
	if (fd != -1)
		close(fd);
	free(buf);
	if (iov != NULL)
		free_iovec(&iov, &iovlen);
	errno = saved_errno;
	return (-1);
}
