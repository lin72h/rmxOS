#ifndef NXPLATFORM_PLIST_TO_LAUNCH_DATA_H
#define NXPLATFORM_PLIST_TO_LAUNCH_DATA_H

#include <launch.h>

launch_data_t plist_to_launch_data_file(const char *path, char *error,
    size_t error_size);

#endif
