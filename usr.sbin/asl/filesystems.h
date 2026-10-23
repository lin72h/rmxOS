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
asl_filesystems_token(int fd, void *bytes, size_t size)
{
 struct stat st;
 return fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == 0 &&
  !(st.st_mode & 022) && st.st_size == (off_t)size &&
  read(fd, bytes, size) == (ssize_t)size;
}

static int
asl_wait_for_filesystems(void)
{
 struct timeval boot, observed;
 unsigned char identity[16], saved[16];
 size_t size = sizeof(identity);
 if (sysctlbyname("kern.boot_id", identity, &size, NULL, 0) != 0 ||
     size != sizeof(identity)) return -1;
 /* kern.boottime moves when the wall clock is corrected. After the first
  * rc handshake, use the kernel's immutable per-boot identity on restarts.
  * A prior boot's file cannot release the first job before FILESYSTEMS. */
 int fd = open("/var/run/asld.filesystems-boot-id", O_RDONLY | O_NOFOLLOW);
 if (fd >= 0) {
  int ready = asl_filesystems_token(fd, saved, sizeof(saved)) &&
   memcmp(identity, saved, sizeof(saved)) == 0;
  close(fd);
  if (ready) return 0;
 }
 size = sizeof(boot);
 if (sysctlbyname("kern.boottime", &boot, &size, NULL, 0) != 0 || size != sizeof(boot)) return -1;
 for (unsigned i = 0; i < 1200; i++) {
  fd = open("/var/run/asld.filesystems-ready", O_RDONLY | O_NOFOLLOW);
  if (fd >= 0) {
   int ready = asl_filesystems_token(fd, &observed, sizeof(observed)) &&
    observed.tv_sec == boot.tv_sec && observed.tv_usec == boot.tv_usec;
   close(fd);
   if (ready) {
    fd = open("/var/run/asld.filesystems-boot-id", O_WRONLY | O_CREAT | O_NOFOLLOW, 0600);
    if (fd < 0) return -1;
    struct stat st;
    int valid = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == 0 &&
     !(st.st_mode & 022);
    int written = valid && write(fd, identity, sizeof(identity)) == sizeof(identity) &&
     ftruncate(fd, sizeof(identity)) == 0;
    int error = errno;
    close(fd);
    if (!written) { errno = valid ? error : EINVAL; return -1; }
    return 0;
   }
  }
  const struct timespec interval = { 0, 100000000 };
  nanosleep(&interval, NULL);
 }
 errno = ETIMEDOUT;
 return -1;
}
#endif
