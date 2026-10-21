#ifndef ASL_STARTUP_ERROR_H
#define ASL_STARTUP_ERROR_H
/* Returns zero when both console and classic boot-log writes complete. */
int asl_startup_report(const char *, const char *, int);
#endif
