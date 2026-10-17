/* SPDX-License-Identifier: BSD-2-Clause */
#ifndef _JOB_REQUEST_OWNERSHIP_H_
#define _JOB_REQUEST_OWNERSHIP_H_

/* job_mig_ipc_request releases its received mapping, moved rights and asport
 * on every reached exit. MIG has also released/cleared the input array by
 * this point. A transport must not destroy those resources a second time.
 * A generated check failure never reaches this annotation. */
#define MIG_SERVER_REQUEST_CONSUMED_ipc_request(head) \
    ((head)->msgh_bits &= ~MACH_MSGH_BITS_COMPLEX)

#endif
