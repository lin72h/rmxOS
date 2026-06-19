/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Advisory Darwin QoS pthread-attribute shims for imported libdispatch.
 */

#include <sys/cdefs.h>

#include <pthread.h>
#include <pthread/qos.h>

int
pthread_attr_get_qos_class_np(const pthread_attr_t *attr __unused,
    qos_class_t *qos_class, int *relative_priority)
{
	if (qos_class != NULL)
		*qos_class = QOS_CLASS_DEFAULT;
	if (relative_priority != NULL)
		*relative_priority = 0;
	return (0);
}

int
pthread_attr_set_qos_class_np(pthread_attr_t *attr __unused,
    qos_class_t qos_class __unused, int relative_priority __unused)
{
	return (0);
}
