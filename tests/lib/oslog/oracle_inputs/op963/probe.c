#include <os/log.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/resource.h>

#define TAG "rmxop963-20261023T041823Z"
static void stamp(const char *phase) {
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    printf("%s epoch=%lld.%09ld pid=%d\n", phase, (long long)t.tv_sec, t.tv_nsec, getpid());
    fflush(stdout);
}
static void types(os_log_t log, const char *name) {
    os_log_type_t types[] = {OS_LOG_TYPE_DEFAULT, OS_LOG_TYPE_INFO, OS_LOG_TYPE_DEBUG, OS_LOG_TYPE_ERROR, OS_LOG_TYPE_FAULT};
    const char *names[] = {"default", "info", "debug", "error", "fault"};
    for (unsigned i = 0; i < sizeof(types)/sizeof(types[0]); i++)
        printf("enabled log=%s type=%s value=0x%02x enabled=%d\n", name, names[i], types[i], os_log_type_enabled(log,types[i]));
    os_log(log, TAG " fields macro=default log=%{public}s", name);
    os_log_info(log, TAG " fields macro=info log=%{public}s", name);
    os_log_debug(log, TAG " fields macro=debug log=%{public}s", name);
    os_log_error(log, TAG " fields macro=error log=%{public}s", name);
    os_log_fault(log, TAG " fields macro=fault log=%{public}s", name);
    for (unsigned i = 0; i < sizeof(types)/sizeof(types[0]); i++)
        os_log_with_type(log, types[i], TAG " fields with_type=%{public}s log=%{public}s", names[i], name);
}
int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr,"usage: probe base|object|decoder\n"); return 2; }
    stamp("start");
    os_log_t log = os_log_create("org.rmxos.op963", "test");
    char runtime[128];
    snprintf(runtime, sizeof(runtime), "runtime-%s", argv[1]);
    printf("tag=%s runtime=%s pointer=%p\n", TAG, runtime, (void *)runtime);
    fflush(stdout);
    if (!strcmp(argv[1], "object")) {
        struct rlimit core = {0,0};
        if (setrlimit(RLIMIT_CORE, &core)) { perror("setrlimit"); return 2; }
        const char *object = "C-STRING-NOT-AN-OBJC-OBJECT";
        os_log(log, TAG " object before");
        puts("calling object conversion with const char *"); fflush(stdout);
#ifndef EXCLUDE_OBJECT
        os_log(log, TAG " object value=%@", object);
#else
        (void)object; return 3;
#endif
        os_log(log, TAG " object after");
        puts("object conversion returned"); fflush(stdout);
    } else if (!strcmp(argv[1], "decoder")) {
        os_log(log, TAG " decoder before");
#ifndef EXCLUDE_DECODER
        os_log(log, TAG " decoder value=%{rmxnope}d", 12345);
#else
        return 3;
#endif
        os_log(log, TAG " decoder after");
    } else if (!strcmp(argv[1], "base")) {
        os_log(log, TAG " begin");
        os_log(log, TAG " privacy s_literal=[%s]", "literal-text");
        os_log(log, TAG " privacy s_runtime=[%s]", runtime);
        os_log(log, TAG " privacy d=[%d]", -12345);
        os_log(log, TAG " privacy u=[%u]", 424242u);
        os_log(log, TAG " privacy x=[%x]", 0x1a2b3cu);
        os_log(log, TAG " privacy p=[%p]", (void *)runtime);
        os_log(log, TAG " privacy f=[%f]", 3.25);
        os_log(log, TAG " privacy c=[%c]", 'Q');
        os_log(log, TAG " privacy public_literal=[%{public}s]", "literal-text");
        os_log(log, TAG " privacy public_runtime=[%{public}s]", runtime);
        os_log(log, TAG " privacy private_literal=[%{private}s]", "literal-text");
        os_log(log, TAG " privacy private_runtime=[%{private}s]", runtime);
        types(OS_LOG_DEFAULT, "OS_LOG_DEFAULT");
        types(log, "created");
        types(OS_LOG_DISABLED, "OS_LOG_DISABLED");
        char long_string[2001];
        memset(long_string, 'A', 2000); long_string[2000] = '\0';
        os_log(log, TAG " long begin[%{public}s]end", long_string);
        os_log(log, TAG " end");
    } else { fprintf(stderr,"unknown mode\n"); return 2; }
    stamp("end");
    return 0;
}
