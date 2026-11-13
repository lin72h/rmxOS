/*
 * Host compile case: the fake CrashReporterClient API is an expression, so
 * LLVM's (void)CRSetCrashLogMessage(msg) compiles, and the tree's own
 * statement uses (os/assumes.h, notifyd) still do.
 * cc -fsyntax-only -Wall -Werror -isystem <include> crash_reporter_client.c
 */
#include <CrashReporterClient.h>
#include <os/assumes.h>

void	cast_form(const char *msg);
void	statement_forms(const char *msg);

void
cast_form(const char *msg)
{

	(void)CRSetCrashLogMessage(msg);
}

void
statement_forms(const char *msg)
{

	CRSetCrashLogMessage(msg);
	os_set_crash_message(msg);
}
