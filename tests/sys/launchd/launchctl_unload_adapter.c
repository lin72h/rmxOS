/* ABI projection of the production command; the mock and assertions are Zig. */
int rmx_launchctl_main(int, char * const []);
int rmx_unload(const char *);
#define main rmx_launchctl_main
#define bootstrap_port launchctl_bootstrap_port
#ifndef RMX_LAUNCHCTL_SOURCE
#define RMX_LAUNCHCTL_SOURCE "../../../bin/launchctl/launchctl.c"
#endif
#include RMX_LAUNCHCTL_SOURCE
int rmx_unload(const char *path) { return unload_job(path); }
