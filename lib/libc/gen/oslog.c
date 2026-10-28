/* SPDX-License-Identifier: BSD-2-Clause */
/* os_log user API. Only flattened public bytes reach the logging transport. */
#include <sys/types.h>
#include <sys/elf_common.h>
#include <sys/syscall.h>
#include <sys/time.h>

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <link.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#include "asl_private.h"
#include "oslog_codec.h"

/* Match os_object's immortal prefix, including libdispatch's global xref.
 * The kind is separate: default and disabled are both actual objects. */
struct os_log_s {
	const void *isa;
	int refcnt, xrefcnt;
	unsigned kind;
	const char *subsystem, *category;
	struct os_log_s *next;
};
struct os_log_s _os_log_default = { NULL, INT_MAX, INT_MAX, 0, "", "", NULL };
struct os_log_s _os_log_disabled = { NULL, INT_MAX, INT_MAX, 1, "", "", NULL };
static struct os_log_s *objects;
static pthread_mutex_t object_lock = PTHREAD_MUTEX_INITIALIZER;
/* Shared with syslog(3), which owns the transport's cached Mach rights. */
extern __hidden pthread_mutex_t __libc_syslog_mutex;
static _Atomic uint64_t sequence;

/* libdispatch supplies the generic non-log object operations when linked.
 * Its own os_retain/os_release also recognize the immortal xref prefix. */
extern void *_os_object_retain(void *) __attribute__((weak));
extern void _os_object_release(void *) __attribute__((weak));
void *
os_retain(void *object)
{
	void *(*retain)(void *) = _os_object_retain;
	if (object == NULL || ((struct os_log_s *)object)->xrefcnt == INT_MAX)
		return (object);
	if (retain == NULL)
		retain = (void *(*)(void *))dlsym(RTLD_DEFAULT,
		    "_os_object_retain");
	if (retain != NULL)
		return (retain(object));
	abort();
}
void
os_release(void *object)
{
	void (*release)(void *) = _os_object_release;
	if (object == NULL || ((struct os_log_s *)object)->xrefcnt == INT_MAX)
		return;
	if (release == NULL)
		release = (void (*)(void *))dlsym(RTLD_DEFAULT,
		    "_os_object_release");
	if (release != NULL) {
		release(object);
		return;
	}
	abort();
}

os_log_t
os_log_create(const char *subsystem, const char *category)
{
	struct os_log_s *log;

	if (subsystem == NULL || category == NULL) {
		errno = EINVAL;
		return (OS_LOG_DISABLED);
	}
	pthread_mutex_lock(&object_lock);
	for (log = objects; log != NULL; log = log->next)
		if (strcmp(log->subsystem, subsystem) == 0 &&
		    strcmp(log->category, category) == 0)
			break;
	if (log == NULL) {
		log = calloc(1, sizeof(*log));
		if (log != NULL) {
			log->subsystem = strdup(subsystem);
			log->category = strdup(category);
			if (log->subsystem == NULL || log->category == NULL) {
				free((void *)(uintptr_t)log->subsystem);
				free((void *)(uintptr_t)log->category);
				free(log);
				log = NULL;
			} else {
				log->refcnt = log->xrefcnt = INT_MAX;
				log->next = objects;
				objects = log;
			}
		}
	}
	pthread_mutex_unlock(&object_lock);
	return (log != NULL ? log : OS_LOG_DISABLED);
}
bool
os_log_type_enabled(os_log_t log, os_log_type_t type)
{
	return (log != NULL && log->kind != 1 &&
	    (type == OS_LOG_TYPE_DEFAULT || type == OS_LOG_TYPE_INFO ||
		type == OS_LOG_TYPE_ERROR || type == OS_LOG_TYPE_FAULT));
}
bool
os_log_info_enabled(os_log_t log)
{
	return (os_log_type_enabled(log, 1));
}
bool
os_log_debug_enabled(os_log_t log)
{
	return (os_log_type_enabled(log, 2));
}

/* A kernel copyin through an owned pipe validates every public byte without
 * installing signal handlers or dereferencing a possibly invalid argument.
 * Private strings never enter this reader. */
static int
read_byte(void *context, uintptr_t pointer, size_t offset, unsigned char *byte)
{
	int *fds = context;
	ssize_t n;

	if (pointer > UINTPTR_MAX - offset)
		return (EFAULT);
	do
		n = syscall(SYS_write, fds[1], (const void *)(pointer + offset),
		    (size_t)1);
	while (n < 0 && errno == EINTR);
	if (n != 1)
		return (EFAULT);
	do
		n = read(fds[0], byte, 1);
	while (n < 0 && errno == EINTR);
	return (n == 1 ? 0 : EFAULT);
}
static void
field(FILE *fp, const char *key, const char *value)
{
	const unsigned char *p;

	fprintf(fp, "[org.rmxos.logd.%s ", key);
	/* ASL distinguishes a missing value from an empty string. */
	if (*value == 0)
		fputs("\\000", fp);
	for (p = (const void *)value; *p != 0; p++) {
		if (*p == '\\' || *p == '[' || *p == ']')
			fputc('\\', fp);
		if (*p == '\n')
			fputs("\\n", fp);
		else if (*p == '\r')
			fputs("\\r", fp);
		else
			fputc(*p, fp);
	}
	fputs("] ", fp);
}
static void
image_fields(FILE *fp, const void *pc)
{
	struct dl_phdr_info info;
	const Elf_Phdr *ph;
	const unsigned char *p, *end;
	Elf_Nhdr note;
	char id[129] = "", relative[32];
	size_t names, desc, i;
	uintptr_t image_base = UINTPTR_MAX;

	if (!_rtld_addr_phdr(pc, &info)) {
		memset(&info, 0, sizeof(info));
		info.dlpi_name = "";
	}
	for (i = 0; i < info.dlpi_phnum; i++) {
		ph = &info.dlpi_phdr[i];
		if (ph->p_type == PT_LOAD &&
		    ph->p_vaddr <= UINTPTR_MAX - info.dlpi_addr &&
		    info.dlpi_addr + ph->p_vaddr < image_base)
			image_base = info.dlpi_addr + ph->p_vaddr;
		if (ph->p_type != PT_NOTE || ph->p_memsz < sizeof(note))
			continue;
		p = (const void *)(info.dlpi_addr + ph->p_vaddr);
		end = p + ph->p_memsz;
		while ((size_t)(end - p) >= sizeof(note)) {
			memcpy(&note, p, sizeof(note));
			p += sizeof(note);
			names = ((size_t)note.n_namesz + 3) & ~(size_t)3;
			desc = ((size_t)note.n_descsz + 3) & ~(size_t)3;
			if (names > (size_t)(end - p) ||
			    desc > (size_t)(end - p) - names)
				break;
			if (note.n_type == NT_GNU_BUILD_ID &&
			    note.n_namesz == 4 && memcmp(p, "GNU\0", 4) == 0 &&
			    note.n_descsz <= 64) {
				for (unsigned j = 0; j < note.n_descsz; j++)
					snprintf(id + j * 2, 3, "%02x",
					    p[names + j]);
			}
			p += names + desc;
		}
	}
	field(fp, "senderImagePath",
	    info.dlpi_name != NULL ? info.dlpi_name : "");
	field(fp, "senderImageBuildID", id);
	snprintf(relative, sizeof(relative), "%" PRIuPTR,
	    image_base <= (uintptr_t)pc ? (uintptr_t)pc - image_base : 0);
	field(fp, "senderImagePC", relative);
}
static void
emit(os_log_t log, os_log_type_t type, const char *format,
    const uint8_t *buffer, uint32_t size, const void *pc)
{
	unsigned char flat[__OSLOG_CODEC_STORAGE];
	char message[65536 + 8192], host[256], number[64], *base,
	    *record = NULL;
	struct timeval now;
	struct timespec uptime;
	size_t length, used, record_size;
	long tid = 0;
	int fds[2], saved = errno;
	FILE *fp;

	if (!os_log_type_enabled(log, type) || format == NULL ||
	    strnlen(format, 65537) > 65536)
		goto done;
	if (pipe2(fds, O_CLOEXEC) != 0)
		goto done;
	int error = __oslog_codec_flatten(buffer, size, type, read_byte, fds,
	    flat, sizeof(flat), &length);
	close(fds[0]);
	close(fds[1]);
	if (error != 0 ||
	    __oslog_codec_render(format, strlen(format), flat, length, message,
		sizeof(message), &used) != 0)
		goto done;
	gettimeofday(&now, NULL);
	if (gethostname(host, sizeof(host)) != 0)
		host[0] = 0;
	host[sizeof(host) - 1] = 0;
	base = __libc_asl_record(getprogname(), getpid(),
	    LOG_USER |
		(type == 1	   ? LOG_INFO :
			type == 16 ? LOG_ERR :
			type == 17 ? LOG_CRIT :
				     LOG_NOTICE),
	    &now, host, message, 0);
	if (base == NULL)
		goto done;
	fp = open_memstream(&record, &record_size);
	if (fp == NULL) {
		free(base);
		goto done;
	}
	fputs(base, fp);
	free(base);
	snprintf(number, sizeof(number), "%u", type);
	field(fp, "type", number);
	field(fp, "subsystem", log->subsystem);
	field(fp, "category", log->category);
	field(fp, "formatString", format);
	(void)syscall(SYS_thr_self, &tid);
	snprintf(number, sizeof(number), "%ld", tid);
	field(fp, "threadID", number);
	clock_gettime(CLOCK_UPTIME_PRECISE, &uptime);
	snprintf(number, sizeof(number), "%" PRIu64,
	    (uint64_t)uptime.tv_sec * 1000000000 + uptime.tv_nsec);
	field(fp, "machTimestamp", number);
	image_fields(fp, pc);
	snprintf(number, sizeof(number), "%" PRIu64,
	    ((uint64_t)(uint32_t)getpid() << 32) ^
		(atomic_fetch_add_explicit(&sequence, 1, memory_order_relaxed) +
		    1));
	field(fp, "traceID", number);
	if (fclose(fp) == 0) {
		pthread_mutex_lock(&__libc_syslog_mutex);
		(void)__libc_asl_send(record);
		pthread_mutex_unlock(&__libc_syslog_mutex);
	}
	free(record);
done:
	errno = saved;
}
#define ENTRY(name)                                                    \
	void name(const void *image, os_log_t log, os_log_type_t type, \
	    const char *format, const uint8_t *buffer, uint32_t size)  \
	{                                                              \
		(void)image;                                           \
		emit(log, type, format, buffer, size,                  \
		    __builtin_return_address(0));                      \
	}
ENTRY(_os_log_impl)
ENTRY(_os_log_debug_impl)
ENTRY(_os_log_error_impl)
ENTRY(_os_log_fault_impl)
