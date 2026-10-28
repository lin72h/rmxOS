/* Compiler inputs used only by the host sanitizer harness. Zig checks exits. */
#include <stddef.h>
void codec_asan_control(unsigned char *p, size_t n) { p[n] = 1; }
int codec_ubsan_control(int n) { return n + 1; }
