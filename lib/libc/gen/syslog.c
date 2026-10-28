/*-
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Copyright (c) 1983, 1988, 1993
 *	The Regents of the University of California.  All rights reserved.
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

#include "namespace.h"
#include <sys/param.h>
#include <sys/syslog.h>
#include <sys/time.h>
#include <sys/uio.h>

#include <errno.h>
#include <fcntl.h>
#include <paths.h>
#include <pthread.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <stdarg.h>
#include "un-namespace.h"

#include "libc_private.h"
#include "asl_private.h"

__attribute__((visibility("hidden"))) int __libc_asl_open(void);
__attribute__((visibility("hidden"))) void __libc_asl_close(void);

/* Maximum number of characters of syslog message */
#define	MAXLINE		8192

static int	LogStat = 0;		/* status bits, set by openlog() */
static pid_t	LogPid = -1;		/* process id to tag the entry with */
static const char *LogTag = NULL;	/* string to tag the entry with */
static int	LogTagLength = -1;	/* usable part of LogTag */
static int	LogFacility = LOG_USER;	/* default facility code */
static int	LogMask = 0xff;		/* mask of priorities to be logged */
/* Protected by syslog_mutex; inherited counts belong only to the parent. */
static uint64_t LogRefused;
static pid_t LogRefusedPid;
static struct timespec LogReportTime;
__hidden pthread_mutex_t __libc_syslog_mutex = PTHREAD_MUTEX_INITIALIZER;
#define syslog_mutex __libc_syslog_mutex

#define	THREAD_LOCK()							\
	do { 								\
		if (__isthreaded) _pthread_mutex_lock(&syslog_mutex);	\
	} while(0)
#define	THREAD_UNLOCK()							\
	do {								\
		if (__isthreaded) _pthread_mutex_unlock(&syslog_mutex);	\
	} while(0)

/* RFC5424 defined value. */
#define NILVALUE "-"

static void	openlog_unlocked(const char *, int, int);
static void	parse_tag(void);	/* parse ident[NNN] if needed */

/*
 * Format of the magic cookie passed through the stdio hook
 */
struct bufcookie {
	char	*base;	/* start of buffer */
	int	left;
};

/*
 * stdio write hook for writing to a static string buffer
 * XXX: Maybe one day, dynamically allocate it so that the line length
 *      is `unlimited'.
 */
static int
writehook(void *cookie, const char *buf, int len)
{
	struct bufcookie *h;	/* private `handle' */

	h = (struct bufcookie *)cookie;
	if (len > h->left) {
		/* clip in case of wraparound */
		len = h->left;
	}
	if (len > 0) {
		(void)memcpy(h->base, buf, len); /* `write' it. */
		h->base += len;
		h->left -= len;
	}
	return len;
}

/*
 * syslog, vsyslog --
 *	print message on log file; output is intended for syslogd(8).
 */
void
syslog(int pri, const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vsyslog(pri, fmt, ap);
	va_end(ap);
}

static int
log_send(int pri, const struct timeval *now, const char *host,
    const char *sender, int pid, const char *message, uint64_t dropped)
{
	char *record;
	int result;

	record = __libc_asl_record(sender, pid, pri, now, host, message, dropped);
	if (record == NULL)
		return (-1);
	result = __libc_asl_send(record);
	free(record);
	return (result);
}

static void
vsyslog1(int pri, const char *fmt, va_list ap)
{
	struct timeval now = {0};
	struct tm tm;
	char ch, *p;
	long tz_offset;
	int cnt, fd, saved_errno, body_offset;
	char sender[MAXLINE], body[MAXLINE];
	char hostname[MAXHOSTNAMELEN], *stdp, tbuf[MAXLINE], fmt_cpy[MAXLINE],
	    errstr[64], tz_sign;
	FILE *fp, *fmt_fp;
	struct bufcookie tbuf_cookie;
	struct bufcookie fmt_cookie;

#define	INTERNALLOG	LOG_ERR|LOG_CONS|LOG_PERROR|LOG_PID
	/* Check for invalid bits. */
	if (pri & ~(LOG_PRIMASK|LOG_FACMASK)) {
		syslog(INTERNALLOG,
		    "syslog: unknown facility/priority: %x", pri);
		pri &= LOG_PRIMASK|LOG_FACMASK;
	}

	saved_errno = errno;

	/* Check priority against setlogmask values. */
	if (!(LOG_MASK(LOG_PRI(pri)) & LogMask))
		return;

	/* Set default facility if none specified. */
	if ((pri & LOG_FACMASK) == 0)
		pri |= LogFacility;

	/* Create the primary stdio hook */
	tbuf_cookie.base = tbuf;
	tbuf_cookie.left = sizeof(tbuf);
	fp = fwopen(&tbuf_cookie, writehook);
	if (fp == NULL)
		return;

	/* Build the message according to RFC 5424. Tag and version. */
	(void)fprintf(fp, "<%d>1 ", pri);
	/* Timestamp similar to RFC 3339. */
	if (gettimeofday(&now, NULL) == 0 &&
	    localtime_r(&now.tv_sec, &tm) != NULL) {
		if (tm.tm_gmtoff < 0) {
			tz_sign = '-';
			tz_offset = -tm.tm_gmtoff;
		} else {
			tz_sign = '+';
			tz_offset = tm.tm_gmtoff;
		}

		(void)fprintf(fp,
		    "%04d-%02d-%02d"		/* Date. */
		    "T%02d:%02d:%02d.%06ld"	/* Time. */
		    "%c%02ld:%02ld ",		/* Time zone offset. */
		    tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
		    tm.tm_hour, tm.tm_min, tm.tm_sec, now.tv_usec,
		    tz_sign, tz_offset / 3600, (tz_offset % 3600) / 60);
	} else
		(void)fputs(NILVALUE " ", fp);
	/* Hostname. */
	(void)gethostname(hostname, sizeof(hostname));
	(void)fprintf(fp, "%s ",
	    hostname[0] == '\0' ? NILVALUE : hostname);
	if (LogStat & LOG_PERROR) {
		/* Transfer to string buffer */
		(void)fflush(fp);
		stdp = tbuf + (sizeof(tbuf) - tbuf_cookie.left);
	}
	/* Application name. */
	if (LogTag == NULL)
		LogTag = _getprogname();
	else if (LogTagLength == -1)
		parse_tag();
	if (LogTagLength > 0)
		(void)fprintf(fp, "%.*s ", LogTagLength, LogTag);
	else
		(void)fprintf(fp, "%s ", LogTag == NULL ? NILVALUE : LogTag);
	/*
	 * Provide the process ID regardless of whether LOG_PID has been
	 * specified, as it provides valuable information. Many
	 * applications tend not to use this, even though they should.
	 */
	if (LogTagLength <= 0)
		LogPid = getpid();
	(void)fprintf(fp, "%d ", (int)LogPid);
	/* Message ID. */
	(void)fputs(NILVALUE " ", fp);
	/* Structured data. */
	(void)fputs(NILVALUE " ", fp);

	/* Check to see if we can skip expanding the %m */
	if (strstr(fmt, "%m")) {

		/* Create the second stdio hook */
		fmt_cookie.base = fmt_cpy;
		fmt_cookie.left = sizeof(fmt_cpy) - 1;
		fmt_fp = fwopen(&fmt_cookie, writehook);
		if (fmt_fp == NULL) {
			fclose(fp);
			return;
		}

		/*
		 * Substitute error message for %m.  Be careful not to
		 * molest an escaped percent "%%m".  We want to pass it
		 * on untouched as the format is later parsed by vfprintf.
		 */
		for ( ; (ch = *fmt); ++fmt) {
			if (ch == '%' && fmt[1] == 'm') {
				++fmt;
				strerror_r(saved_errno, errstr, sizeof(errstr));
				fputs(errstr, fmt_fp);
			} else if (ch == '%' && fmt[1] == '%') {
				++fmt;
				fputc(ch, fmt_fp);
				fputc(ch, fmt_fp);
			} else {
				fputc(ch, fmt_fp);
			}
		}

		/* Null terminate if room */
		fputc(0, fmt_fp);
		fclose(fmt_fp);

		/* Guarantee null termination */
		fmt_cpy[sizeof(fmt_cpy) - 1] = '\0';

		fmt = fmt_cpy;
	}

	(void)fflush(fp);
	body_offset = tbuf_cookie.base - tbuf;
	/* Message. */
	(void)vfprintf(fp, fmt, ap);
	(void)fclose(fp);

	cnt = sizeof(tbuf) - tbuf_cookie.left;

	/* Remove a trailing newline */
	if (tbuf[cnt - 1] == '\n')
		cnt--;

	/* Output to stderr if requested. */
	if (LogStat & LOG_PERROR) {
		struct iovec iov[2];
		struct iovec *v = iov;

		v->iov_base = stdp;
		v->iov_len = cnt - (stdp - tbuf);
		++v;
		v->iov_base = "\n";
		v->iov_len = 1;
		(void)_writev(STDERR_FILENO, iov, 2);
	}

	/* Keep the traditional stderr/console representation; ASL gets fields. */
	snprintf(sender, sizeof(sender), "%.*s",
	    LogTagLength > 0 ? LogTagLength : (int)strlen(LogTag), LogTag);
	int body_length = cnt > body_offset ? cnt - body_offset : 0;
	memcpy(body, tbuf + body_offset, body_length);
	body[body_length] = '\0';
	if (LogRefusedPid != getpid()) {
		LogRefusedPid = getpid();
		LogRefused = 0;
		LogReportTime = (struct timespec){0};
	}
	if (LogRefused != 0) {
		struct timespec monotonic;
		char report_body[128];

		/* A failed report preserves the count and is not another loss.
		 * Leave at least one monotonic second between attempts. */
		if (clock_gettime(CLOCK_MONOTONIC, &monotonic) == 0 &&
		    ((LogReportTime.tv_sec == 0 && LogReportTime.tv_nsec == 0) ||
		    monotonic.tv_sec - LogReportTime.tv_sec > 1 ||
		    (monotonic.tv_sec - LogReportTime.tv_sec == 1 &&
		    monotonic.tv_nsec >= LogReportTime.tv_nsec))) {
			LogReportTime = monotonic;
			snprintf(report_body, sizeof(report_body),
			    "syslog: could not deliver %" PRIu64 " messages", LogRefused);
			if (log_send(LOG_SYSLOG | LOG_WARNING, &now, hostname, "syslog",
			    LogRefusedPid, report_body, LogRefused) == 0)
				LogRefused = 0;
		}
	}

	if (log_send(pri, &now, hostname, sender, LogPid, body, 0) == 0)
		return;
	{
		pid_t pid = getpid();
		if (LogRefusedPid != pid) {
			LogRefusedPid = pid;
			LogRefused = 0;
		}
		if (LogRefused != UINT64_MAX)
			LogRefused++;
	}

	/*
	 * Output the message to the console; try not to block
	 * as a blocking console should not stop other processes.
	 * Make sure the error reported is the one from the syslogd failure.
	 */
	if (LogStat & LOG_CONS &&
	    (fd = _open(_PATH_CONSOLE, O_WRONLY|O_NONBLOCK|O_CLOEXEC, 0)) >=
	    0) {
		struct iovec iov[2];
		struct iovec *v = iov;

		p = strchr(tbuf, '>') + 3;
		v->iov_base = p;
		v->iov_len = cnt - (p - tbuf);
		++v;
		v->iov_base = "\r\n";
		v->iov_len = 2;
		(void)_writev(fd, iov, 2);
		(void)_close(fd);
	}
}

static void
syslog_cancel_cleanup(void *arg __unused)
{

	THREAD_UNLOCK();
}

void
vsyslog(int pri, const char *fmt, va_list ap)
{

	THREAD_LOCK();
	pthread_cleanup_push(syslog_cancel_cleanup, NULL);
	vsyslog1(pri, fmt, ap);
	pthread_cleanup_pop(1);
}

static void
openlog_unlocked(const char *ident, int logstat, int logfac)
{
	if (ident != NULL) {
		LogTag = ident;
		LogTagLength = -1;
	}
	LogStat = logstat;
	parse_tag();
	if (logfac != 0 && (logfac &~ LOG_FACMASK) == 0)
		LogFacility = logfac;

	if (LogStat & LOG_NDELAY)	/* open immediately */
		(void)__libc_asl_open();
}

void
openlog(const char *ident, int logstat, int logfac)
{

	THREAD_LOCK();
	pthread_cleanup_push(syslog_cancel_cleanup, NULL);
	openlog_unlocked(ident, logstat, logfac);
	pthread_cleanup_pop(1);
}


void
closelog(void)
{
	THREAD_LOCK();
	__libc_asl_close();
	LogTag = NULL;
	LogTagLength = -1;
	THREAD_UNLOCK();
}

/* setlogmask -- set the log mask level */
int
setlogmask(int pmask)
{
	int omask;

	THREAD_LOCK();
	omask = LogMask;
	if (pmask != 0)
		LogMask = pmask;
	THREAD_UNLOCK();
	return (omask);
}

/*
 * Obtain LogPid from LogTag formatted as per RFC 3164,
 * Section 5.3 Originating Process Information:
 *
 * ident[NNN]
 */
static void
parse_tag(void)
{
	char *begin, *end, *p;
	pid_t pid;

	if (LogTag == NULL || (LogStat & LOG_PID) != 0)
		return;
	/*
	 * LogTagLength is -1 if LogTag was not parsed yet.
	 * Avoid multiple passes over same LogTag.
	 */
	LogTagLength = 0;

	/* Check for presence of opening [ and non-empty ident. */
	if ((begin = strchr(LogTag, '[')) == NULL || begin == LogTag)
		return;
	/* Check for presence of closing ] at the very end and non-empty pid. */
	if ((end = strchr(begin + 1, ']')) == NULL || end[1] != 0 ||
	    (end - begin) < 2)
		return;

	/* Check for pid to contain digits only. */
	pid = (pid_t)strtol(begin + 1, &p, 10);
	if (p != end)
		return;

	LogPid = pid;
	LogTagLength = begin - LogTag;
}
