#ifndef MYBAR_TRACKPAD_BRIDGE_H
#define MYBAR_TRACKPAD_BRIDGE_H
#include <stdint.h>

typedef struct { int32_t identifier; float x, y; } MyBarContact;
// count -1 means an invalid/unsupported frame. Data is callback-scoped only.
typedef void (*MyBarTrackpadCallback)(uintptr_t device, const MyBarContact *contacts,
                                     int32_t count, double timestamp);
int mybar_trackpad_bridge_available(void);
int mybar_trackpad_start(MyBarTrackpadCallback callback);
void mybar_trackpad_stop(void);
int mybar_trackpad_device_count(void);
#endif
