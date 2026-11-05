#include "CPowerMetrics.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef void *IOReportSubscriptionRef;
typedef CFMutableDictionaryRef (*CopyChannelsInGroupFn)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef IOReportSubscriptionRef (*CreateSubscriptionFn)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*CreateSamplesFn)(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*CreateSamplesDeltaFn)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef CFStringRef (*ChannelStringFn)(CFDictionaryRef);
typedef int (*ChannelFormatFn)(CFDictionaryRef);
typedef long (*SimpleValueFn)(CFDictionaryRef, int);

struct ThermoBarPowerSampler {
    void *library;
    IOReportSubscriptionRef subscription;
    CFMutableDictionaryRef channels;
    CFDictionaryRef previous;
    CFAbsoluteTime previous_time;
    CreateSamplesFn create_samples;
    CreateSamplesDeltaFn create_delta;
    ChannelStringFn channel_group;
    ChannelStringFn channel_name;
    ChannelFormatFn channel_format;
    SimpleValueFn simple_value;
    long long pending_cpu_energy;
    double pending_cpu_seconds;
    double last_cpu_watts;
    double last_gpu_watts;
    int has_last_cpu;
    int has_last_gpu;
};

static void *load_symbol(void *library, const char *name) {
    return library == NULL ? NULL : dlsym(library, name);
}

static int copy_cf_string(CFStringRef string, char *buffer, CFIndex capacity) {
    return string != NULL && CFStringGetCString(string, buffer, capacity, kCFStringEncodingUTF8);
}

static int ends_with(const char *value, const char *suffix) {
    size_t value_length = strlen(value);
    size_t suffix_length = strlen(suffix);
    return value_length >= suffix_length
        && strcmp(value + value_length - suffix_length, suffix) == 0;
}

static int is_cpu_cluster_total(const char *name) {
    if (ends_with(name, "_CPU") && (strstr(name, "EACC") != NULL || strstr(name, "PACC") != NULL)) {
        return 1;
    }

    const char *token = strrchr(name, ' ');
    token = token == NULL ? name : token + 1;
    if (strcmp(token, "PCPU") == 0 || strcmp(token, "MCPU") == 0) {
        return 1;
    }
    if (strncmp(token, "MCPU", 4) == 0 && token[4] != '\0') {
        for (const char *character = token + 4; *character != '\0'; character++) {
            if (*character < '0' || *character > '9') return 0;
        }
        return 1;
    }
    return 0;
}

static int is_gpu_millijoule_rail(const char *name) {
    return strstr(name, "GPU") != NULL
        && !ends_with(name, "GPU Energy")
        && strstr(name, "Energy") == NULL;
}

ThermoBarPowerSampler *thermobar_power_sampler_create(void) {
    static const char *paths[] = {
        "/usr/lib/libIOReport.dylib",
        "/System/Library/PrivateFrameworks/IOReport.framework/IOReport"
    };

    void *library = NULL;
    for (size_t index = 0; index < sizeof(paths) / sizeof(paths[0]); index++) {
        library = dlopen(paths[index], RTLD_LAZY | RTLD_LOCAL);
        if (library != NULL) break;
    }
    if (library == NULL) return NULL;

    CopyChannelsInGroupFn copy_channels = (CopyChannelsInGroupFn)load_symbol(library, "IOReportCopyChannelsInGroup");
    CreateSubscriptionFn create_subscription = (CreateSubscriptionFn)load_symbol(library, "IOReportCreateSubscription");
    CreateSamplesFn create_samples = (CreateSamplesFn)load_symbol(library, "IOReportCreateSamples");
    CreateSamplesDeltaFn create_delta = (CreateSamplesDeltaFn)load_symbol(library, "IOReportCreateSamplesDelta");
    ChannelStringFn channel_group = (ChannelStringFn)load_symbol(library, "IOReportChannelGetGroup");
    ChannelStringFn channel_name = (ChannelStringFn)load_symbol(library, "IOReportChannelGetChannelName");
    ChannelFormatFn channel_format = (ChannelFormatFn)load_symbol(library, "IOReportChannelGetFormat");
    SimpleValueFn simple_value = (SimpleValueFn)load_symbol(library, "IOReportSimpleGetIntegerValue");

    if (copy_channels == NULL || create_subscription == NULL || create_samples == NULL
        || create_delta == NULL || channel_group == NULL || channel_name == NULL
        || channel_format == NULL || simple_value == NULL) {
        dlclose(library);
        return NULL;
    }

    CFMutableDictionaryRef requested = copy_channels(CFSTR("Energy Model"), NULL, 0, 0, 0);
    if (requested == NULL) {
        dlclose(library);
        return NULL;
    }

    CFMutableDictionaryRef channels = NULL;
    IOReportSubscriptionRef subscription = create_subscription(NULL, requested, &channels, 0, NULL);
    CFRelease(requested);
    if (subscription == NULL || channels == NULL) {
        if (channels != NULL) CFRelease(channels);
        dlclose(library);
        return NULL;
    }

    ThermoBarPowerSampler *sampler = calloc(1, sizeof(ThermoBarPowerSampler));
    if (sampler == NULL) {
        CFRelease(channels);
        CFRelease((CFTypeRef)subscription);
        dlclose(library);
        return NULL;
    }

    sampler->library = library;
    sampler->subscription = subscription;
    sampler->channels = channels;
    sampler->create_samples = create_samples;
    sampler->create_delta = create_delta;
    sampler->channel_group = channel_group;
    sampler->channel_name = channel_name;
    sampler->channel_format = channel_format;
    sampler->simple_value = simple_value;
    sampler->previous = create_samples(subscription, channels, NULL);
    sampler->previous_time = CFAbsoluteTimeGetCurrent();
    if (sampler->previous == NULL) {
        thermobar_power_sampler_destroy(sampler);
        return NULL;
    }
    return sampler;
}

void thermobar_power_sampler_destroy(ThermoBarPowerSampler *sampler) {
    if (sampler == NULL) return;
    if (sampler->previous != NULL) CFRelease(sampler->previous);
    if (sampler->channels != NULL) CFRelease(sampler->channels);
    if (sampler->subscription != NULL) CFRelease((CFTypeRef)sampler->subscription);
    if (sampler->library != NULL) dlclose(sampler->library);
    free(sampler);
}

int thermobar_power_sampler_read(ThermoBarPowerSampler *sampler, ThermoBarPowerReading *reading) {
    if (sampler == NULL || reading == NULL || sampler->previous == NULL) return 0;

    CFDictionaryRef current = sampler->create_samples(sampler->subscription, sampler->channels, NULL);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (current == NULL) return 0;

    double elapsed = now - sampler->previous_time;
    CFDictionaryRef delta = sampler->create_delta(sampler->previous, current, NULL);
    CFRelease(sampler->previous);
    sampler->previous = current;
    sampler->previous_time = now;
    if (delta == NULL || elapsed < 0.20) {
        if (delta != NULL) CFRelease(delta);
        return 0;
    }

    CFArrayRef channels = (CFArrayRef)CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    if (channels == NULL || CFGetTypeID(channels) != CFArrayGetTypeID()) {
        CFRelease(delta);
        return 0;
    }

    long long cpu_direct = 0;
    long long cpu_clusters = 0;
    long long gpu_rails = 0;
    long long gpu_energy = 0;
    int found_cpu_direct = 0;
    int found_cpu_cluster = 0;
    int found_gpu_rail = 0;
    int found_gpu_energy = 0;

    CFIndex count = CFArrayGetCount(channels);
    for (CFIndex index = 0; index < count; index++) {
        CFDictionaryRef channel = (CFDictionaryRef)CFArrayGetValueAtIndex(channels, index);
        if (channel == NULL || sampler->channel_format(channel) != 1) continue;

        char group[128];
        char name[256];
        if (!copy_cf_string(sampler->channel_group(channel), group, sizeof(group))
            || !copy_cf_string(sampler->channel_name(channel), name, sizeof(name))
            || strstr(group, "Energy Model") == NULL) {
            continue;
        }

        long raw = sampler->simple_value(channel, 0);
        if (raw == LONG_MIN || raw < 0) continue;
        if (ends_with(name, "CPU Energy")) {
            cpu_direct += raw;
            found_cpu_direct = 1;
        } else if (is_cpu_cluster_total(name)) {
            cpu_clusters += raw;
            found_cpu_cluster = 1;
        }

        if (ends_with(name, "GPU Energy")) {
            gpu_energy += raw;
            found_gpu_energy = 1;
        } else if (is_gpu_millijoule_rail(name)) {
            gpu_rails += raw;
            found_gpu_rail = 1;
        }
    }
    CFRelease(delta);

    memset(reading, 0, sizeof(*reading));
    if (found_cpu_direct || found_cpu_cluster) {
        long long raw = found_cpu_direct ? cpu_direct : cpu_clusters;
        sampler->pending_cpu_energy += raw;
        sampler->pending_cpu_seconds += elapsed;
        // M5 energy rails arrive in batches. Average over the whole time since the
        // previous non-zero batch, then retain that value until the next refresh.
        if (raw > 0 && sampler->pending_cpu_seconds > 0) {
            double watts = (double)sampler->pending_cpu_energy / sampler->pending_cpu_seconds / 1000.0;
            sampler->pending_cpu_energy = 0;
            sampler->pending_cpu_seconds = 0;
            if (watts >= 0 && watts <= 500) {
                sampler->last_cpu_watts = watts;
                sampler->has_last_cpu = 1;
            }
        }
        if (sampler->has_last_cpu) {
            reading->cpu_watts = sampler->last_cpu_watts;
            reading->has_cpu = 1;
        }
    }
    if (found_gpu_rail || found_gpu_energy) {
        // "GPU Energy" updates independently and is measured in nanojoules.
        // Prefer it whenever present; the millijoule GPU rails can be batched at zero.
        double watts = found_gpu_energy
            ? (double)gpu_energy / elapsed / 1000000000.0
            : (double)gpu_rails / elapsed / 1000.0;
        if ((gpu_energy > 0 || gpu_rails > 0) && watts >= 0 && watts <= 500) {
            sampler->last_gpu_watts = watts;
            sampler->has_last_gpu = 1;
        }
        if (sampler->has_last_gpu) {
            reading->gpu_watts = sampler->last_gpu_watts;
            reading->has_gpu = 1;
        }
    }
    return reading->has_cpu || reading->has_gpu;
}
