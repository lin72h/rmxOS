/* A logger cannot depend on its own socket to report failure before startup. */
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include "startup_error.h"

static int
write_channel(int fd, const char *text, size_t length)
{
 if (fd < 0) return -1;
 ssize_t done;
 do { done = write(fd, text, length); } while (done < 0 && errno == EINTR);
 close(fd);
 return done == (ssize_t)length ? 0 : -1;
}

int
asl_startup_report(const char *service, const char *detail, int error)
{
 char text[512];
 int n = snprintf(text, sizeof(text), "%s[%d]: startup failed: %s%s%s\n",
     service, getpid(), detail, error ? ": " : "", error ? strerror(error) : "");
 if (n < 0) return -1;
 size_t length = (size_t)n < sizeof(text) ? (size_t)n : sizeof(text) - 1;
 int console = write_channel(open("/dev/console", O_WRONLY | O_NONBLOCK | O_NOCTTY), text, length);
 int fd = open("/var/log/messages", O_WRONLY | O_APPEND | O_CREAT | O_NONBLOCK | O_NOFOLLOW, 0644);
 struct stat st;
 if (fd >= 0 && (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode))) { close(fd); fd = -1; }
 int boot_log = write_channel(fd, text, length);
 /* Do these independent writes before stderr, which launchd may pipe. */
 (void)fwrite(text, 1, length, stderr);
 (void)fflush(stderr);
 return console == 0 && boot_log == 0 ? 0 : -1;
}
