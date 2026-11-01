/* ABI projection only; fixture state and assertions are Zig. */
#include <sys/types.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
extern const char *rmx_fs_path(const char *);
extern int rmx_fs_sysctl(const char *, void *, size_t *, const void *, size_t);
extern int rmx_fs_stat(int, struct stat *);
extern int rmx_fs_sleep(const struct timespec *, struct timespec *);
extern int rmx_fs_statfs(const char *, struct statfs *);
static int projected_open(const char *path, int flags, ...) {
 return open(rmx_fs_path(path), flags, 0600);
}
#define open projected_open
#define fstat rmx_fs_stat
#define sysctlbyname rmx_fs_sysctl
#define nanosleep rmx_fs_sleep
/* Function-like, so struct statfs keeps its name. */
#define statfs(path, buf) rmx_fs_statfs(path, buf)
#include "../filesystems.h"
int rmx_fs_wait(void) { return asl_wait_for_filesystems(); }
int rmx_fs_sealed(void) { return asl_sealed_layout(); }
