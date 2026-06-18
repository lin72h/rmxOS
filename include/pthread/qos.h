/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026
 */

#ifndef _PTHREAD_QOS_H_
#define _PTHREAD_QOS_H_

#include <sys/cdefs.h>
#include <stdint.h>
#include <pthread.h>

typedef enum {
	QOS_CLASS_USER_INTERACTIVE = 0x21,
	QOS_CLASS_USER_INITIATED = 0x19,
	QOS_CLASS_DEFAULT = 0x15,
	QOS_CLASS_UTILITY = 0x11,
	QOS_CLASS_BACKGROUND = 0x09,
	QOS_CLASS_MAINTENANCE = 0x05,
	QOS_CLASS_UNSPECIFIED = 0x00,
} qos_class_t;

#define	QOS_MIN_RELATIVE_PRIORITY	(-15)

__BEGIN_DECLS

qos_class_t	qos_class_self(void);
qos_class_t	qos_class_main(void);
int		pthread_set_qos_class_self_np(qos_class_t qos_class,
		    int relative_priority);

__END_DECLS

#endif /* !_PTHREAD_QOS_H_ */
