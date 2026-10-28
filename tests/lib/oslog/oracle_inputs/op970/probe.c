#include "shared.h"
#include "long-literal.h"
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <wchar.h>

static const char const_array[] = "static-const-array";
static char writable_array[] = "static-writable-array";
static void stamp(const char *phase) {
    struct timespec t; clock_gettime(CLOCK_REALTIME,&t);
    printf("%s epoch=%lld.%09ld pid=%d\n",phase,(long long)t.tv_sec,t.tv_nsec,getpid());
    fflush(stdout);
}
static void location(const char *name, const void *p) {
    Dl_info info;
    int found = dladdr(p,&info);
    printf("address name=%s ptr=%p image=%s\n",name,p,found ? info.dli_fname : "NONE");
    fflush(stdout);
}
static void bundle_case(os_log_t log, int nodelete) {
    int flags = RTLD_NOW | RTLD_LOCAL | (nodelete ? RTLD_NODELETE : 0);
    void *handle = dlopen("build/op970/literal.bundle",flags);
    if (!handle) { fprintf(stderr,"dlopen: %s\n",dlerror()); exit(2); }
    const char *(*get)(void) = (const char *(*)(void))dlsym(handle,"bundle_literal");
    if (!get) { fprintf(stderr,"dlsym: %s\n",dlerror()); exit(2); }
    const char *s = get();
    location(nodelete ? "bundle-nodelete-loaded" : "bundle-normal-loaded",s);
    if (nodelete) os_log(log,TAG " A04b value=[%s]",s);
    else os_log(log,TAG " A04a value=[%s]",s);
    if (dlclose(handle)) { fprintf(stderr,"dlclose: %s\n",dlerror()); exit(2); }
    // dladdr only tests the pointer's image registration; do not dereference
    // the pointer after dlclose of the ordinary bundle.
    location(nodelete ? "bundle-nodelete-after-close" : "bundle-normal-after-close",s);
}
int main(void) {
    stamp("start");
    os_log_t log = os_log_create("org.rmxos.op970","test");
    os_log(log,TAG " begin");
    const char *main_literal = "main-literal";
    location("foo-literal",foo_literal());
    location("main-literal",main_literal);
    os_log(log,TAG " A01 value=[%s]",foo_literal());
    foo_log(log,main_literal);
    const char *error = strerror(ENOENT);
    printf("strerror_ENOENT=%s\n",error); location("strerror",error);
    os_log(log,TAG " A03 value=[%s]",error);
    bundle_case(log,0);
    bundle_case(log,1);
    location("static-const",const_array); location("static-writable",writable_array);
    os_log(log,TAG " A05a value=[%s]",const_array);
    os_log(log,TAG " A05b value=[%s]",writable_array);
    os_log(log,TAG " A05c value=[%s]",__func__);
    os_log(log,TAG " A05d value=[%s]","prefix-middle-literal" + 7);
    char *copy = strdup("copied-literal");
    if (!copy) { perror("strdup"); return 2; }
    location("strdup",copy);
    os_log(log,TAG " A05e value=[%s]",copy);
    os_log(log,TAG " A06a value=[%s]",(char *)NULL);
    os_log(log,TAG " A06b value=[%{public}s]",(char *)NULL);
    os_log(log,TAG " A07a value=[%{private}d]",12345);
    os_log(log,TAG " A07b value=[%{sensitive}s]","sensitive-literal");
    os_log(log,TAG " A07c value=[%{public}ls]",L"wide-literal-\u00e9");
    os_log(log,TAG " A07d value=[%ls]",L"wide-literal-\u00e9");
    free(copy);

    char a[2001], a1014[1015], a1015[1016], a1016[1017];
    memset(a,'A',2000); a[2000]=0;
    memset(a1014,'A',1014); a1014[1014]=0;
    memset(a1015,'A',1015); a1015[1015]=0;
    memset(a1016,'A',1016); a1016[1016]=0;
    os_log(log,TAG " B01a s=[%{public}s]",a1014);
    os_log(log,TAG " B01b s=[%{public}s]",a1015);
    os_log(log,TAG " B01c s=[%{public}s]",a1016);
    os_log(log,TAG " B02a n=[%d] s=[%{public}s]",42,a);
    os_log(log,TAG " B02b n=[%ld] s=[%{public}s]",42L,a);
    os_log(log,TAG " B03 s1=[%{public}s] s2=[%{public}s]",a,a);
    os_log(log,TAG " B04 s1=[%{public}s] s2=[%{public}s]","abc",a);
    os_log(log,TAG " B05 private=[%s] s=[%{public}s]",a,a);
    os_log(log,TAG " B06 n=[%{private}ld] s=[%{public}s]",42L,a);
    // Cover both literal formats requested and their explicitly public forms.
    os_log(log,TAG " B07a s=[%{public}.2000s]",a);
    os_log(log,TAG " B07b s=[%{public}.*s]",2000,a);
    os_log(log,TAG " B07c s=[%.2000s]",a);
    os_log(log,TAG " B07d s=[%.*s]",2000,a);
    printf("info_enabled=%d\n",os_log_type_enabled(log,OS_LOG_TYPE_INFO));
    os_log(log,TAG " B08a s=[%{public}s]",a);
    os_log_info(log,TAG " B08b s=[%{public}s]",a);
    os_log_error(log,TAG " B08c s=[%{public}s]",a);
    os_log_fault(log,TAG " B08d s=[%{public}s]",a);
    char short_arg[3]; snprintf(short_arg,sizeof(short_arg),"ok");
    os_log(log,TAG " B09a literal=[" LONG_LITERAL "] short=[%{public}s]",short_arg);
    os_log(log,TAG " B09b s=[%s]",LONG_LITERAL);
    os_log(log,TAG " B09c s=[%{public}s]",LONG_LITERAL);
    char utf8[2001]; memcpy(utf8,a,sizeof(utf8));
    utf8[1014]=(char)0xc3; utf8[1015]=(char)0xa9;
    memcpy(utf8+1016,"-TAIL",5);
    os_log(log,TAG " B10 s=[%{public}s]",utf8);
    char shorts[33][3];
    for (int i=0;i<33;i++) snprintf(shorts[i],sizeof(shorts[i]),"%02d",i+1);
#ifndef EXCLUDE_33
#include "thirty-three.h"
#endif
    os_log(log,TAG " end");
    stamp("end");
    return 0;
}
