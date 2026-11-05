// Private contact ABI informed by SwipeSwitcher (MIT, Afiv Dicky Efendy).
// See THIRD_PARTY_NOTICES.md. Only the isolated helper links this target.
#include "CTrackpadBridge.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <stddef.h>
#include <math.h>

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;
typedef struct {
    int32_t frame; double timestamp;
    int32_t identifier, state, fingerID, handID;
    MTVector normalized; float size; int32_t unknown1;
    float angle, majorAxis, minorAxis;
    MTVector absolute; int32_t unknown2, unknown3; float density;
} MTTouch;
_Static_assert(sizeof(MTTouch) == 96, "Unsupported private touch layout");
_Static_assert(offsetof(MTTouch, normalized) == 32, "Unsupported touch coordinates");

typedef void *MTDeviceRef;
typedef int (*MTCallback)(MTDeviceRef, const MTTouch *, int32_t, double, int32_t);
static CFArrayRef (*create_list)(void);
static void (*register_callback)(MTDeviceRef, MTCallback);
static void (*unregister_callback)(MTDeviceRef, MTCallback);
static int32_t (*start_device)(MTDeviceRef, int32_t);
static int32_t (*stop_device)(MTDeviceRef);
static CFArrayRef devices;
static void *library;
static MyBarTrackpadCallback sink; // Assigned once before registrations, lives until process exit.
static atomic_bool running = false;

int mybar_trackpad_bridge_available(void) {
    if (library) return create_list && register_callback && unregister_callback && start_device && stop_device;
    library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LOCAL | RTLD_NOW);
    if (!library) return 0;
    create_list = dlsym(library, "MTDeviceCreateList");
    register_callback = dlsym(library, "MTRegisterContactFrameCallback");
    unregister_callback = dlsym(library, "MTUnregisterContactFrameCallback");
    start_device = dlsym(library, "MTDeviceStart");
    stop_device = dlsym(library, "MTDeviceStop");
    // Never dlclose: framework threads may retain callback addresses until exit.
    return create_list && register_callback && unregister_callback && start_device && stop_device;
}

static int receive_frame(MTDeviceRef device, const MTTouch *touches, int32_t count, double timestamp, int32_t frame) {
    (void)frame;
    if (!atomic_load_explicit(&running, memory_order_acquire)) return 0;
    if (count < 0 || count > 16 || (count > 0 && !touches) || !isfinite(timestamp)) {
        sink((uintptr_t)device, NULL, -1, timestamp); return 0;
    }
    MyBarContact contacts[16]; int active = 0;
    for (int i = 0; i < count; ++i) {
        // 3 making contact, 4 touching; hover and liftoff are not held fingers.
        if (touches[i].state != 3 && touches[i].state != 4) continue;
        float x = touches[i].normalized.position.x, y = touches[i].normalized.position.y;
        if (!isfinite(x) || !isfinite(y) || x < 0 || x > 1 || y < 0 || y > 1) {
            sink((uintptr_t)device, NULL, -1, timestamp); return 0;
        }
        contacts[active++] = (MyBarContact){touches[i].identifier, x, y};
    }
    sink((uintptr_t)device, contacts, active, timestamp);
    return 0;
}

int mybar_trackpad_device_count(void) {
    if (!mybar_trackpad_bridge_available()) return -1;
    CFArrayRef list = create_list();
    if (!list) return 0;
    CFIndex count = CFArrayGetCount(list); CFRelease(list);
    return count <= 8 ? (int)count : -1;
}

int mybar_trackpad_start(MyBarTrackpadCallback callback) {
    if (devices) return (int)CFArrayGetCount(devices);
    if (!callback || !mybar_trackpad_bridge_available()) return -1;
    devices = create_list();
    if (!devices) return 0;
    if (CFArrayGetCount(devices) > 8) { CFRelease(devices); devices = NULL; return -1; }
    if (!sink) sink = callback;
    atomic_store_explicit(&running, true, memory_order_release);
    for (CFIndex i = 0; i < CFArrayGetCount(devices); ++i) {
        MTDeviceRef device = (void *)CFArrayGetValueAtIndex(devices, i);
        register_callback(device, receive_frame);
        start_device(device, 0);
    }
    return (int)CFArrayGetCount(devices);
}

void mybar_trackpad_stop(void) {
    atomic_store_explicit(&running, false, memory_order_release);
    if (!devices) return;
    for (CFIndex i = 0; i < CFArrayGetCount(devices); ++i) {
        MTDeviceRef device = (void *)CFArrayGetValueAtIndex(devices, i);
        unregister_callback(device, receive_frame); stop_device(device);
    }
    CFRelease(devices); devices = NULL;
}
