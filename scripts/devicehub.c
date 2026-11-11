// Posts the private HID events Xcode's Device Hub sends to a simulator: the iPhone Duo's hinge (0 shut, 180 flat) and
// the device's orientation, which turns the Duo's screens where an app's own rotation request doesn't. Runs inside the
// simulator (`xcrun simctl spawn`); scripts/shots builds it. Undocumented, so a new Xcode may change it.
//
// Adapted from https://github.com/artemnovichkov/hinge (via Maestro #3621 and ace #1427).
// Copyright (c) 2026 Artem Novichkov. Licensed under the MIT License: Permission is hereby granted, free of charge, to
// any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the
// Software without restriction, including without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to
// do so, subject to the following conditions: The above copyright notice and this permission notice shall be included
// in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED.

#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
extern IOHIDEventRef IOHIDEventCreateVendorDefinedEvent(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, const uint8_t *, CFIndex, uint32_t);
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(CFAllocatorRef, int, CFDictionaryRef);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef, IOHIDEventRef);
extern CFDataRef IOCFSerialize(CFTypeRef, CFOptionFlags);

static IOHIDEventSystemClientRef client;

static void post(CFStringRef source, CFStringRef type, CFTypeRef value) {
    const void *keys[] = {CFSTR("provider"), CFSTR("source"), CFSTR("type"), CFSTR("value")};
    const void *values[] = {CFSTR("com.apple.Virtualization"), source, type, value};
    CFDictionaryRef payload = CFDictionaryCreate(NULL, keys, values, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDataRef data = IOCFSerialize(payload, 1);
    IOHIDEventRef event = IOHIDEventCreateVendorDefinedEvent(NULL, mach_absolute_time(), 0xFF61, 0x5B, 0, CFDataGetBytePtr(data), CFDataGetLength(data), 0);
    IOHIDEventSystemClientDispatchEvent(client, event);
    CFRelease(event);
    CFRelease(data);
    CFRelease(payload);
}

static void hinge(double degrees) {
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberDoubleType, &degrees);
    post(CFSTR("hinge-slider-control"), CFSTR("range"), value);
    CFRelease(value);
}

int main(int argc, char **argv) {
    client = IOHIDEventSystemClientCreateWithType(NULL, 4, NULL);
    if (argc >= 3 && !strcmp(argv[1], "hinge") && client) {
        double to = fmin(fmax(atof(argv[2]), 0), 180), from = 180 - to;
        for (int step = 1; step <= 36; step++) {
            double t = step / 36.0;
            hinge(from + (to - from) * (1 - pow(1 - t, 3)));
            usleep(16000);
        }
        // The system follows the hinge as a motion and settles on the last reading.
        for (int i = 0; i < 20; i++) {
            hinge(to);
            usleep(30000);
        }
        return 0;
    }
    if (argc == 3 && !strcmp(argv[1], "orientation") && client) {
        CFStringRef value = CFStringCreateWithCString(NULL, argv[2], kCFStringEncodingUTF8);
        post(CFSTR("orientation-picker-control"), CFSTR("enum"), value);
        usleep(100000);
        return 0;
    }
    fprintf(stderr, "usage: devicehub hinge <0-180> | devicehub orientation portrait|landscape-left|landscape-right\n");
    return 64;
}
