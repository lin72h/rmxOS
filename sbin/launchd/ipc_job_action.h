/* Stop and removal start asynchronous operations with no errno result. */
#ifndef LAUNCHD_IPC_JOB_ACTION_H
#define LAUNCHD_IPC_JOB_ACTION_H
#include <errno.h>
struct job_s;
static inline int
ipc_job_action(struct job_s *job, void (*action)(struct job_s *))
{
	if (job == NULL)
		return (ESRCH);
	action(job);
	return (0);
}
#endif
