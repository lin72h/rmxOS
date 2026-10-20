/* System jobs may be launched before rc mounts /var and clears /var/run. */
#ifndef ASL_FILESYSTEMS_H
#define ASL_FILESYSTEMS_H
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <time.h>
static int
asl_wait_for_filesystems(void)
{
 struct timeval boot, observed;
 size_t size = sizeof(boot);
 if (sysctlbyname("kern.boottime", &boot, &size, NULL, 0) != 0 || size != sizeof(boot)) return -1;
 for (unsigned i = 0; i < 1200; i++) {
  int fd = open("/var/run/asld.filesystems-ready", O_RDONLY | O_NOFOLLOW);
  if (fd >= 0) {
   struct stat st;
   int ready = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == 0 &&
    !(st.st_mode & 022) && st.st_size == sizeof(observed) &&
    read(fd, &observed, sizeof(observed)) == sizeof(observed) &&
    observed.tv_sec == boot.tv_sec && observed.tv_usec == boot.tv_usec;
   close(fd);
   if (ready) return 0;
  }
  const struct timespec interval = { 0, 100000000 };
  nanosleep(&interval, NULL);
 }
 errno = ETIMEDOUT;
 return -1;
}
#endif
