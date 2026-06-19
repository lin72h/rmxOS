/* Build-only declarations hidden by the imported Darwin compatibility macros. */
#ifndef RMX_LAUNCHD_BUILD_COMPAT_H
#define RMX_LAUNCHD_BUILD_COMPAT_H

#include <sys/types.h>
#include <mach/message.h>
#include <bsm/audit.h>

void audit_token_to_au32(audit_token_t atoken, uid_t *auidp, uid_t *euidp,
    gid_t *egidp, uid_t *ruidp, gid_t *rgidp, pid_t *pidp,
    au_asid_t *asidp, au_tid_t *tidp);

#endif
