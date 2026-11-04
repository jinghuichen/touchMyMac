//
//  HIDInterpreter.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#ifndef HIDInterpreter_h
#define HIDInterpreter_h

#include <stdio.h>
#include <CoreFoundation/CoreFoundation.h>

void OpenHIDManager(void *delegate);

void CloseHIDManager(void);

/// Product name of the touchscreen being read, or NULL when none is connected. The caller releases it.
CFStringRef HIDCopyActiveTouchscreenName(void);

#endif /* HIDInterpreter_h */
