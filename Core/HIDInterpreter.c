//
//  HIDInterpreter.c
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#include "HIDInterpreter.h"
#include "TUCTouchInputManager-C.h"

#include <mach/mach_port.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDManager.h>

#include <CoreGraphics/CoreGraphics.h>

#pragma mark - Global variables

static void* gTouchManager;

static CFRunLoopRef gRunLoopRef;

static IOHIDManagerRef gHidManager;

IOHIDQueueRef gQueue;


uint8_t gAreElementRefsSet = 0;
Boolean gTouchscreenCollectionFound = FALSE; // values from other collections are ignored

IOHIDElementRef         gApplicationCollectionElement;
IOHIDElementRef         gScanTimeElement;
CFMutableArrayRef       gTouchCollectionElements;

/**
 stores values for the touch collections: cookie -> latest value
 in hybrid mode (especially if order of touches moves) this data has to be set to last state per collection element receiving touches now
 */
CFMutableDictionaryRef  gStoredInputValues; //


CFIndex gContactCount = 1;
CFIndex gHybridOffset = 0; // how many touches are already sent until this point?
Boolean gTouchscreenUsesHybridMode = FALSE;


CFMutableArrayRef gContactIdentifiers;


/**
 Setup can fail right after login: a login item may start before its HID access is usable,
 and the matching callback fires only once per device. So a failed setup retries for a while.
 */
static CFRunLoopTimerRef gSetupRetryTimer;
static int gSetupRetryCount = 0;
static const int kMaxSetupRetries = 15;
static const CFTimeInterval kSetupRetryInterval = 2.0;
static Boolean gManagerOpenFailed = FALSE; // values don't arrive even if a queue gets created

static void ScheduleSetupRetry(void);
static void CancelSetupRetry(void);
static void TearDownHIDManager(void);
static void StopCertificationRead(void);
static IOHIDElementRef ApplicationCollectionOfElement(IOHIDElementRef element);


#pragma mark General Debug Utilities




void PrintAddress(UInt8 *ptr, UInt64 length) {
    for (int i=0; i<length; i++) {
        printf("%02x ", ptr[i]);
        if ((i+1)%8 == 0) printf("  ");
        if ((i+1)%32 == 0) printf("\n");
    }
    printf("\n");
}


void PrintInput(IOHIDValueRef inHIDValue) {
    IOHIDElementRef elem = IOHIDValueGetElement(inHIDValue);
    CFIndex page = IOHIDElementGetUsagePage(elem);
    CFIndex usage = IOHIDElementGetUsage(elem);
    CFIndex value = IOHIDValueGetIntegerValue(inHIDValue);
    
    IOHIDElementCookie cookie = IOHIDElementGetCookie(elem);
    
    char pageDescr[6]  = "(---)";
    char usageDescr[10] = "(-------)";
    
    if (page == kHIDPage_GenericDesktop) {
        strcpy(pageDescr, "(GD) ");
        if (usage == kHIDUsage_GD_X) {
            strcpy(usageDescr, "(X)      ");
        } else if (usage == kHIDUsage_GD_Y) {
            strcpy(usageDescr, "(Y)      ");
        }
        
    } else if (page == kHIDPage_Digitizer) {
        strcpy(pageDescr, "(Dig)");
        
        if (usage == kHIDUsage_Dig_TipSwitch) {
            strcpy(usageDescr, "(Tip)    ");
        } else if (usage == kHIDUsage_Dig_ContactIdentifier) {
            strcpy(usageDescr, "(Cont ID)");
        } else if (usage == kHIDUsage_Dig_ContactCount) {
            strcpy(usageDescr, "(ContCnt)");
        } else if (usage == kHIDUsage_Dig_TouchValid) {
            strcpy(usageDescr, "(IsValid)");
        } else if (usage == kHIDUsage_Dig_RelativeScanTime) {
            strcpy(usageDescr, "(ScnTime)");
        } else if (usage == kHIDUsage_Dig_Width) {
            strcpy(usageDescr, "(Width)  ");
        } else if (usage == kHIDUsage_Dig_Height) {
            strcpy(usageDescr, "(Height) ");
        } else if (usage == kHIDUsage_Dig_Azimuth) {
            strcpy(usageDescr, "(Azimuth)");
        }
    }
    
    CFIndex  lMin = IOHIDElementGetLogicalMin(elem);
    CFIndex lMax = IOHIDElementGetLogicalMax(elem);
    
    printf("%u\t| %#02lx %s\t| %#02lx %s\t|%8ld\t(%ld-%ld)\n", cookie, page, pageDescr, usage, usageDescr, value, lMin, lMax);
}





#pragma mark - Storing Values


int64_t StorageKeyForElement(IOHIDElementRef element) {
    return IOHIDElementGetCookie(element);
}



CFIndex ValueOfElement(IOHIDElementRef element) {
    
    if (!element) {
        return kCFNotFound;
    }
    
    int64_t hash = StorageKeyForElement(element);
    CFNumberRef key = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &hash);
    
    if (CFDictionaryContainsKey(gStoredInputValues, key)) {
        CFIndex value;
        CFNumberRef num = CFDictionaryGetValue(gStoredInputValues, key);
        CFNumberGetValue(num, kCFNumberCFIndexType, &value);
        CFRelease(key);
        return value;
        
    }
    return kCFNotFound;

}



void StoreInputValue(IOHIDValueRef hidValue) {
    
    CFIndex value = IOHIDValueGetIntegerValue(hidValue);
    IOHIDElementRef elem = IOHIDValueGetElement(hidValue);
    
    CFIndex keyValue = StorageKeyForElement(elem);
    
    CFNumberRef key = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &keyValue);
    
    CFNumberRef num = CFNumberCreate(kCFAllocatorDefault, kCFNumberCFIndexType, &value);
    
    CFDictionarySetValue(gStoredInputValues, key, num);
    
    CFRelease(num);
    CFRelease(key);
    
    
    // special case: contact count could be zero in hybrid mode --> s
    CFIndex page = IOHIDElementGetUsagePage(elem);
    CFIndex usage = IOHIDElementGetUsage(elem);
    
    if (page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_ContactCount) {
        // hybrid mode can only exist if the old value is larger than the number of collections that can be communicated at once
        CFIndex numCollections =  CFArrayGetCount(gTouchCollectionElements);
        
        if (gContactCount > numCollections && value == 0 && gHybridOffset > 0) {
            gTouchscreenUsesHybridMode = TRUE;
            
        } else {
            gContactCount = value;
            gHybridOffset = 0;
        }
    }
}




/**
 We need to inspect the HID tree as a whole once to see which elements are grouped into logical groups of touch data.
 Just pass in any element of the tree, the function will walk up the tree, search for the logical groups and rememeber them in the global variables.
 */
void IdentifyElements(IOHIDElementRef anyElement, Boolean printTree) {
    
    IOHIDElementRef applicationCollection = anyElement;
    IOHIDElementType type = kIOHIDElementTypeOutput;
    
    while (type != kIOHIDElementCollectionTypeApplication) {
        IOHIDElementRef next = IOHIDElementGetParent(applicationCollection);
        if (next) {
            applicationCollection = next;
            type = IOHIDElementGetType(applicationCollection);
        } else {
            break;
        }
    }
    
    gApplicationCollectionElement = applicationCollection;
    CFArrayRemoveAllValues(gTouchCollectionElements); // so a second pass doesn't list every contact twice
    
    CFArrayRef children = IOHIDElementGetChildren(applicationCollection);
    CFIndex numChildren = children != NULL ? CFArrayGetCount(children) : 0;
    
    if (printTree) {
        printf("# parent (type %u) has %ld children:\n", type, numChildren);
    }
    
    
    for (CFIndex i=0; i<numChildren; i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(children, i);
        
        CFIndex page = IOHIDElementGetUsagePage(element);
        CFIndex usage = IOHIDElementGetUsage(element);
        IOHIDElementType type =  IOHIDElementGetType(element);
        IOHIDElementCollectionType collectionType = IOHIDElementGetCollectionType(element);
        
        if (type == kIOHIDElementTypeCollection && collectionType == kIOHIDElementCollectionTypeLogical) {
            CFArrayAppendValue(gTouchCollectionElements, element);
            
            if (printTree) {
                printf(" > Logical collection %ld\n", i);
                CFArrayRef grandchildren = IOHIDElementGetChildren(element);
                for( CFIndex j=0; j<CFArrayGetCount(grandchildren); j++) {
                    IOHIDElementRef gch = (IOHIDElementRef)CFArrayGetValueAtIndex(grandchildren, j);
                    CFIndex page = IOHIDElementGetUsagePage(gch);
                    CFIndex usage = IOHIDElementGetUsage(gch);
                    CFIndex cookie= IOHIDElementGetCookie(gch);
                    
                    printf("    > %#02lx %#02lx  [%ld]\n", page, usage, cookie);
                }
            }
            
        } // logical collection
        
        else if (page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_ContactCount) {
            if (printTree) {
                printf(" > Contact Count\n");
            }
        }
        
        else if (page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_RelativeScanTime) {
            gScanTimeElement = element;
            if (printTree) {
                printf(" > Scan Time\n");
            }
        }
        
        else {
            if (printTree) {
                printf(" > %#02lx %#02lx\n", page, usage);
            }
        }
    }
}









#pragma mark - Propagate Touch Data to next layer


void PrintTouchCollection(IOHIDElementRef collection) {
    CFArrayRef children = IOHIDElementGetChildren(collection);
    
    // get stored values of all touches
    for (CFIndex i=0; i<CFArrayGetCount(children); i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(children, i);
        
        CFIndex page = IOHIDElementGetUsagePage(element);
        CFIndex usage = IOHIDElementGetUsage(element);
        CFIndex cookie = IOHIDElementGetCookie(element);
        CFIndex value = ValueOfElement(element);
        
        char pageDescr[6]  = "(---)";
        char usageDescr[10] = "(-------)";
        
        if (page == kHIDPage_GenericDesktop) {
            strcpy(pageDescr, "(GD) ");
            if (usage == kHIDUsage_GD_X) {
                strcpy(usageDescr, "(X)      ");
            } else if (usage == kHIDUsage_GD_Y) {
                strcpy(usageDescr, "(Y)      ");
            }
            
        } else if (page == kHIDPage_Digitizer) {
            strcpy(pageDescr, "(Dig)");
            
            if (usage == kHIDUsage_Dig_TipSwitch) {
                strcpy(usageDescr, "(Tip)    ");
            } else if (usage == kHIDUsage_Dig_ContactIdentifier) {
                strcpy(usageDescr, "(Cont ID)");
            } else if (usage == kHIDUsage_Dig_ContactCount) {
                strcpy(usageDescr, "(ContCnt)");
            } else if (usage == kHIDUsage_Dig_TouchValid) {
                strcpy(usageDescr, "(IsValid)");
            } else if (usage == kHIDUsage_Dig_RelativeScanTime) {
                strcpy(usageDescr, "(ScnTime)");
            } else if (usage == kHIDUsage_Dig_Width) {
                strcpy(usageDescr, "(Width)  ");
            } else if (usage == kHIDUsage_Dig_Height) {
                strcpy(usageDescr, "(Height) ");
            } else if (usage == kHIDUsage_Dig_Azimuth) {
                strcpy(usageDescr, "(Azimuth)");
            }
        }
        
        
        
        printf("[%u]\t%#02lx\t%#02lx %s\t %8ld\n", cookie, page, usage, usageDescr,  value);
    }
    printf("\n");
}


/**
 Dispatches touch data for the given collection, but only if all values needed were received
 */

/**
 Some panels declare X and Y with a report count of 2 and send the 16-bit value twice,
 which macOS reads as one 32-bit value. Recover it when both halves agree.
 */
static CFIndex UnpackDuplicatedCoordinate(CFIndex value, CFIndex logicalMax) {
    if (value <= logicalMax) {
        return value;
    }
    CFIndex low = value & 0xFFFF;
    CFIndex high = (value >> 16) & 0xFFFF;
    return (low == high && low <= logicalMax) ? low : value;
}

void DispatchTouchDataForCollection(IOHIDElementRef collection) {
    
    CFArrayRef children = IOHIDElementGetChildren(collection);

    CGFloat x = -1;
    CGFloat y = -1;
    
    CFIndex contactID = 0;
    CFIndex tipSwitch = 0;
    CFIndex isValid = 0;
    
    CFIndex width   = kCFNotFound;
    CFIndex height  = kCFNotFound;
    CFIndex azimuth = kCFNotFound;
    
    // get stored values of all touches
    for (CFIndex i=0; i<CFArrayGetCount(children); i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(children, i);
        
        CFIndex page = IOHIDElementGetUsagePage(element);
        CFIndex usage = IOHIDElementGetUsage(element);
        CFIndex value = ValueOfElement(element);
        
        if (value != kCFNotFound) {
            if (page == kHIDPage_GenericDesktop) {
                if (usage == kHIDUsage_GD_X) {
                    CGFloat min = (CGFloat)IOHIDElementGetLogicalMin(element);
                    CGFloat max = (CGFloat)IOHIDElementGetLogicalMax(element);
                    CGFloat curr = (CGFloat)UnpackDuplicatedCoordinate(value, IOHIDElementGetLogicalMax(element));
                    x = ( (curr - min) / (max - min) ) + min;
                }
                
                else if (usage == kHIDUsage_GD_Y) {
                    CGFloat min = (CGFloat)IOHIDElementGetLogicalMin(element);
                    CGFloat max = (CGFloat)IOHIDElementGetLogicalMax(element);
                    CGFloat curr = (CGFloat)UnpackDuplicatedCoordinate(value, IOHIDElementGetLogicalMax(element));
                    y = ( (curr - min) / (max - min) ) + min;
                }
            } //kHIDPage_GenericDesktop
            
            else if (page == kHIDPage_Digitizer) {
                if (usage == kHIDUsage_Dig_ContactIdentifier) {
                    contactID = value;
                } else if (usage == kHIDUsage_Dig_TipSwitch) {
                    tipSwitch = value;
                } else if (usage == kHIDUsage_Dig_TouchValid) {
                    isValid = value;
                } else if (usage == kHIDUsage_Dig_Width) {
                    width = value;
                } else if (usage == kHIDUsage_Dig_Height) {
                    height = value;
                } else if (usage == kHIDUsage_Dig_Azimuth) {
                    azimuth = value;
                }
            } // kHIDPage_Digitizer
        }
    }
    TouchInputManagerUpdateTouchPosition(gTouchManager, contactID, x, y, (int)tipSwitch, (int)isValid);
    
//    if (width != kCFNotFound && height != kCFNotFound && azimuth != kCFNotFound) {
//        TouchInputManagerUpdateTouchSize(gTouchManager, contactID, (CGFloat)width, (CGFloat)height, (CGFloat)azimuth);
//    }
    
}



void DispatchTouches(void) {

    CFIndex numCollections = CFArrayGetCount(gTouchCollectionElements);
    CFIndex remainingUpdates = gContactCount - gHybridOffset;
    
    CFIndex numUpdates = numCollections;
    if (remainingUpdates < numCollections) {
        numUpdates = remainingUpdates;
    }
    
//    if(gTouchscreenUsesHybridMode && gHybridOffset > 0) {
//        printf("Update NEXT %ld out of %ld touches beginning with %ld \n", numUpdates, gContactCount, gHybridOffset);
//        
//    } else {
//        printf("Update %ld out of %ld touches beginning with %ld \n", numUpdates, gContactCount, gHybridOffset);
//    }
    
    CFIndex numElementsToPost = CFArrayGetCount(gTouchCollectionElements);
    if (numUpdates < numElementsToPost)
        numElementsToPost = numUpdates;
    
    // update the touch data
    for (CFIndex i=0; i<numElementsToPost; i++) {
        IOHIDElementRef collection = (IOHIDElementRef)CFArrayGetValueAtIndex(gTouchCollectionElements, i);
        DispatchTouchDataForCollection(collection);
//        PrintTouchCollection(collection);
    }
    
    gHybridOffset = gHybridOffset + numUpdates;
    
    if (gHybridOffset == gContactCount) {
        gHybridOffset = 0;
    }

    if (gHybridOffset == 0) {
        TouchInputManagerDidProcessReport(gTouchManager);
    }
    
}






#pragma mark - Callbacks

/*!
    @param context void * pointer to your data, often a pointer to an object.
    @param result Completion result of desired operation.
    @param inSender Interface instance sending the completion routine.
*/

static void Handle_QueueValueAvailable(
            void * _Nullable        context,
            IOReturn                result,
            void * _Nullable        inSender
) {
    
    do {
        IOHIDValueRef valueRef = IOHIDQueueCopyNextValueWithTimeout((IOHIDQueueRef) inSender, 0.);
        if (!valueRef)  {
            // finished processing 1 report
            DispatchTouches();
            break;
        }
        // process the HID value reference
        StoreInputValue(valueRef);
        
        // Don't forget to release our HID value reference
        CFRelease(valueRef);
    } while (1) ;
}


static void Handle_InputValueCallback (
                void *          inContext,      // context from IOHIDManagerRegisterInputValueCallback
                IOReturn        inResult,       // completion result for the input value operation
                void *          inSender,       // the IOHIDManagerRef
                IOHIDValueRef   inIOHIDValueRef // the new element value
) {
    IOHIDElementRef elem = IOHIDValueGetElement(inIOHIDValueRef);

    // A panel can share its interface with mouse or keyboard collections. In mouse emulation
    // those are the only ones reporting, and they would be mistaken for the touch data.
    if (gTouchscreenCollectionFound) {
        IOHIDElementRef application = ApplicationCollectionOfElement(elem);
        if (application == NULL || !CFEqual(application, gApplicationCollectionElement)) {
            return;
        }
    }

    if(!gAreElementRefsSet) {
        IdentifyElements(elem, TRUE);
        gAreElementRefsSet = 1;
    }
    
    if (gQueue == NULL) {
        // If we haven't set up the device queue yet, there's nowhere to route values.
        // The matching callback should create/schedule/start gQueue; this guard avoids a crash
        // and lets the system retry when the queue becomes available.
        return;
    }

    Boolean added = IOHIDQueueContainsElement(gQueue, elem);
    if(!added) {
        IOHIDQueueAddElement(gQueue, elem);
        StoreInputValue(inIOHIDValueRef);
    }
    
}








#pragma mark - Multi-Touch Mode

/// Usages Windows touch panels use to leave mouse emulation (not in IOHIDUsageTables.h).
#define kTUCHIDUsage_Dig_DeviceMode 0x52
#define kTUCDeviceModeMultiInput    2
#define kTUCHIDPage_Vendor          0xFF00
#define kTUCHIDUsage_Vendor_DeviceCertificationStatus 0xC5

static const int kMaxCertificationReadAttempts = 20;
static const CFTimeInterval kCertificationRetryInterval = 0.5;

static CFRunLoopTimerRef gCertificationTimer;
static IOHIDDeviceRef gCertificationDevice;
static IOHIDElementRef gCertificationElement;
static int gCertificationAttempts = 0;
static uint8_t gCertificationBuffer[257];

static IOHIDElementRef ApplicationCollectionOfElement(IOHIDElementRef element) {
    for (IOHIDElementRef current = element; current != NULL; current = IOHIDElementGetParent(current)) {
        if (IOHIDElementGetType(current) == kIOHIDElementTypeCollection
            && IOHIDElementGetCollectionType(current) == kIOHIDElementCollectionTypeApplication) {
            return current;
        }
    }
    return NULL;
}

/// The first element of `device` with this type and usage, or NULL. Not retained.
static IOHIDElementRef FindElement(IOHIDDeviceRef device, IOHIDElementType type, uint32_t page, uint32_t usage) {
    CFArrayRef elements = IOHIDDeviceCopyMatchingElements(device, NULL, kIOHIDOptionsTypeNone);
    if (elements == NULL) {
        return NULL;
    }
    IOHIDElementRef found = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(elements) && found == NULL; i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
        Boolean typeMatches = IOHIDElementGetType(element) == type
            && (type != kIOHIDElementTypeCollection
                || IOHIDElementGetCollectionType(element) == kIOHIDElementCollectionTypeApplication);
        if (typeMatches && IOHIDElementGetUsagePage(element) == page && IOHIDElementGetUsage(element) == usage) {
            found = element;
        }
    }
    CFRelease(elements); // the device keeps its elements alive
    return found;
}

static void StopCertificationRead(void) {
    if (gCertificationTimer != NULL) {
        CFRunLoopTimerInvalidate(gCertificationTimer);
        gCertificationTimer = NULL;
    }
    if (gCertificationDevice != NULL) {
        CFRelease(gCertificationDevice);
        gCertificationDevice = NULL;
    }
    gCertificationElement = NULL;
    gCertificationAttempts = 0;
}

static void ReadCertificationStatus(CFRunLoopTimerRef timer, void *info);

static void Handle_CertificationReport(void *context, IOReturn result, void *sender, IOHIDReportType type,
                                       uint32_t reportID, uint8_t *report, CFIndex reportLength) {
    if (gCertificationDevice == NULL) {
        return; // stopped while the read was pending
    }
    if (result == kIOReturnSuccess) {
        fprintf(stderr, "%s: read the certification status, panel should leave mouse emulation\n", __PRETTY_FUNCTION__);
        StopCertificationRead();
    } else if (gCertificationAttempts >= kMaxCertificationReadAttempts) {
        fprintf(stderr, "%s: certification status unreadable (0x%x), giving up\n", __PRETTY_FUNCTION__, result);
        StopCertificationRead();
    } else {
        gCertificationTimer = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + kCertificationRetryInterval,
                                                   0, 0, 0, ReadCertificationStatus, NULL);
        CFRunLoopAddTimer(CFRunLoopGetMain(), gCertificationTimer, kCFRunLoopCommonModes);
        CFRelease(gCertificationTimer); // the run loop keeps it until it fires
    }
}

static void ReadCertificationStatus(CFRunLoopTimerRef timer, void *info) {
    gCertificationTimer = NULL;
    gCertificationAttempts++;
    CFIndex length = sizeof(gCertificationBuffer);
    // Asynchronous with a timeout: the first reads often time out while the controller settles.
    IOReturn result = IOHIDDeviceGetReportWithCallback(gCertificationDevice, kIOHIDReportTypeFeature,
                                                       IOHIDElementGetReportID(gCertificationElement),
                                                       gCertificationBuffer, &length, 1.0,
                                                       Handle_CertificationReport, gCertificationBuffer);
    if (result != kIOReturnSuccess) {
        Handle_CertificationReport(gCertificationBuffer, result, gCertificationDevice, kIOHIDReportTypeFeature, 0, gCertificationBuffer, 0);
    }
}

/**
 Many touch panels made for Windows start as a single absolute mouse and only send multi-touch
 reports once the host switches them, which Windows does on connect and macOS never does.
 Both ways are tried; panels already in multi-touch mode ignore them.
 */
static void EnableMultiTouchMode(IOHIDDeviceRef device) {
    // The standard way: write Device Mode = Multi-Input.
    IOHIDElementRef deviceMode = FindElement(device, kIOHIDElementTypeFeature, kHIDPage_Digitizer, kTUCHIDUsage_Dig_DeviceMode);
    if (deviceMode != NULL && IOHIDElementGetLogicalMax(deviceMode) >= kTUCDeviceModeMultiInput) {
        IOHIDValueRef value = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, deviceMode, 0, kTUCDeviceModeMultiInput);
        if (value != NULL) {
            IOReturn result = IOHIDDeviceSetValue(device, deviceMode, value);
            CFRelease(value);
            fprintf(stderr, "%s: set Device Mode to multi-input: 0x%x\n", __PRETTY_FUNCTION__, result);
        }
    }

    // Some controllers (e.g. ELAN) switch once the host reads their certification status instead.
    StopCertificationRead();
    IOHIDElementRef certification = FindElement(device, kIOHIDElementTypeFeature, kTUCHIDPage_Vendor,
                                                kTUCHIDUsage_Vendor_DeviceCertificationStatus);
    if (certification != NULL) {
        gCertificationDevice = (IOHIDDeviceRef)CFRetain(device);
        gCertificationElement = certification;
        ReadCertificationStatus(NULL, NULL);
    }
}


// this will be called when the HID Manager matches a new (hot plugged) HID device
static void Handle_DeviceMatchingCallback(
            void *          inContext,       // context from IOHIDManagerRegisterDeviceMatchingCallback
            IOReturn        inResult,        // the result of the matching operation
            void *          inSender,        // the IOHIDManagerRef for the new device
            IOHIDDeviceRef  inIOHIDDeviceRef // the new HID device
) {
    printf("%s(context: %p, result: %p, sender: %p, device: %p).\n",
        __PRETTY_FUNCTION__, inContext, (void *) inResult, inSender, (void*) inIOHIDDeviceRef);
   
    // This interpreter currently supports a single active touchscreen queue.
    // If we already have one, ignore additional matching callbacks.
    if (gQueue != NULL) {
        return;
    }

    // Find the touchscreen collection explicitly instead of from whichever value arrives first.
    gAreElementRefsSet = 0;
    IOHIDElementRef touchscreen = FindElement(inIOHIDDeviceRef, kIOHIDElementTypeCollection,
                                              kHIDPage_Digitizer, kHIDUsage_Dig_TouchScreen);
    gTouchscreenCollectionFound = touchscreen != NULL;
    if (touchscreen != NULL) {
        IdentifyElements(touchscreen, TRUE);
        gAreElementRefsSet = 1;
        if (CFArrayGetCount(gTouchCollectionElements) == 0) {
            // A digitizer without contacts we can read (like a built-in one) must not take the
            // single touchscreen slot from the panel that comes after it.
            fprintf(stderr, "%s: skipping a touchscreen without readable contacts\n", __PRETTY_FUNCTION__);
            gTouchscreenCollectionFound = FALSE;
            gAreElementRefsSet = 0;
            gApplicationCollectionElement = NULL;
            return;
        }
    }
    
    
    IOHIDQueueRef queue = IOHIDQueueCreate(kCFAllocatorDefault, inIOHIDDeviceRef, 1000, kNilOptions);
    if (queue == NULL) {
        fprintf(stderr, "%s: IOHIDQueueCreate failed\n", __PRETTY_FUNCTION__);
        ScheduleSetupRetry();
        return;
    }
    
    IOHIDQueueRegisterValueAvailableCallback(queue, Handle_QueueValueAvailable, NULL);
    IOHIDQueueScheduleWithRunLoop(queue, gRunLoopRef, kCFRunLoopCommonModes);
    IOHIDQueueStart(queue);
    gQueue = queue;
    if (!gManagerOpenFailed) {
        CancelSetupRetry();
    }
    EnableMultiTouchMode(inIOHIDDeviceRef);
    
    TouchInputManagerDidConnectTouchscreen(gTouchManager);
    
}   // Handle_DeviceMatchingCallback
 


// this will be called when a HID device is removed (unplugged)
static void Handle_RemovalCallback(
                void *         inContext,       // context from IOHIDManagerRegisterDeviceMatchingCallback
                IOReturn       inResult,        // the result of the removing operation
                void *         inSender,        // the IOHIDManagerRef for the device being removed
                IOHIDDeviceRef inIOHIDDeviceRef // the removed HID device
) {
    printf("%s(context: %p, result: %p, sender: %p, device: %p).\n",
        __PRETTY_FUNCTION__, inContext, (void *) inResult, inSender, (void*) inIOHIDDeviceRef);
    if (gQueue != NULL) {
        IOHIDQueueStop(gQueue);
        CFRelease(gQueue);
        gQueue = NULL;
    }
    
    if (gTouchCollectionElements != NULL) {
        CFArrayRemoveAllValues(gTouchCollectionElements);
    }
    if (gContactIdentifiers != NULL) {
        CFArrayRemoveAllValues(gContactIdentifiers);
    }
    if (gStoredInputValues != NULL) {
        CFDictionaryRemoveAllValues(gStoredInputValues);
    }
    StopCertificationRead();
    gAreElementRefsSet = 0;
    gTouchscreenCollectionFound = FALSE;
    
    TouchInputManagerDidDisconnectTouchscreen(gTouchManager);
}   // Handle_RemovalCallback



#pragma mark - Start / Stop


// function to create matching dictionary
static CFMutableDictionaryRef CreateDeviceMatchingDictionary(UInt32 inUsagePage, UInt32 inUsage) {
    // create a dictionary to add usage page/usages to
    CFMutableDictionaryRef result = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (result) {
        if (inUsagePage) {
            // Add key for device type to refine the matching dictionary.
            CFNumberRef pageCFNumberRef = CFNumberCreate(
                            kCFAllocatorDefault, kCFNumberIntType, &inUsagePage);
            if (pageCFNumberRef) {
                CFDictionarySetValue(result,
                        CFSTR(kIOHIDDeviceUsagePageKey), pageCFNumberRef);
                CFRelease(pageCFNumberRef);
 
                // note: the usage is only valid if the usage page is also defined
                if (inUsage) {
                    CFNumberRef usageCFNumberRef = CFNumberCreate(
                                    kCFAllocatorDefault, kCFNumberIntType, &inUsage);
                    if (usageCFNumberRef) {
                        CFDictionarySetValue(result,
                            CFSTR(kIOHIDDeviceUsageKey), usageCFNumberRef);
                        CFRelease(usageCFNumberRef);
                    } else {
                        fprintf(stderr, "%s: CFNumberCreate(usage) failed.", __PRETTY_FUNCTION__);
                    }
                }
            } else {
                fprintf(stderr, "%s: CFNumberCreate(usage page) failed.", __PRETTY_FUNCTION__);
            }
        }
    } else {
        fprintf(stderr, "%s: CFDictionaryCreateMutable failed.", __PRETTY_FUNCTION__);
    }
    return result;
}   // CreateDeviceMatchingDictionary
 




void OpenHIDManager(void *delegate) {
    gTouchManager = delegate;
    
    // If Open is called twice within one process, make sure we start clean.
    TearDownHIDManager();
    
    gHidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    
    if (CFGetTypeID(gHidManager) != IOHIDManagerGetTypeID()) {
        printf("OH CRAP THIS IS NOT AN HID MANAGER");
    }
        
    
    gTouchCollectionElements = CFArrayCreateMutable(kCFAllocatorDefault, 0, NULL);
    gContactIdentifiers      = CFArrayCreateMutable(kCFAllocatorDefault, 0, NULL);
    gStoredInputValues       = CFDictionaryCreateMutable(kCFAllocatorDefault,0, NULL, NULL);
   
//    CFMutableDictionaryRef keyboard =
//    CreateDeviceMatchingDictionary(kHIDPage_Digitizer, kHIDUsage_Dig_Pen);
//    CFMutableDictionaryRef keypad =
//    CreateDeviceMatchingDictionary(kHIDPage_Digitizer, kHIDUsage_Dig_Touch);

    CFMutableDictionaryRef matchesList[] = {
        CreateDeviceMatchingDictionary(kHIDPage_Digitizer, kHIDUsage_Dig_TouchScreen),
    };
    

    
    CFArrayRef matches = CFArrayCreate(kCFAllocatorDefault,
            (const void **)matchesList, 1, NULL);
    IOHIDManagerSetDeviceMatchingMultiple(gHidManager, matches);
    CFRelease(matches);
    
    IOHIDManagerRegisterDeviceMatchingCallback(gHidManager, Handle_DeviceMatchingCallback, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(gHidManager, Handle_RemovalCallback, NULL);
    
//    IOHIDManagerRegisterInputReportWithTimeStampCallback(gHidManager, Handle_ReportCallback, NULL);
    IOHIDManagerRegisterInputValueCallback(gHidManager, Handle_InputValueCallback, NULL);
    
    
    gRunLoopRef = CFRunLoopGetMain();
    
    IOHIDManagerScheduleWithRunLoop(gHidManager, gRunLoopRef,
                                    kCFRunLoopCommonModes);

    IOReturn openRes = IOHIDManagerOpen(gHidManager, kIOHIDOptionsTypeNone);
    gManagerOpenFailed = openRes != kIOReturnSuccess;
    if (openRes != kIOReturnSuccess) {
        fprintf(stderr, "%s: IOHIDManagerOpen failed: 0x%x\n", __PRETTY_FUNCTION__, openRes);
        ScheduleSetupRetry();
    }

    // Some systems don't reliably invoke the matching callback for already-attached devices
    // at app start. Force an enumeration pass and initialize the queue immediately.
    if (gQueue == NULL) {
        CFSetRef devices = IOHIDManagerCopyDevices(gHidManager);
        if (devices != NULL) {
            CFIndex count = CFSetGetCount(devices);
            if (count > 0) {
                IOHIDDeviceRef *values = (IOHIDDeviceRef *)calloc((size_t)count, sizeof(IOHIDDeviceRef));
                if (values != NULL) {
                    CFSetGetValues(devices, (const void **)values);
                    for (CFIndex i = 0; i < count; i++) {
                        if (gQueue != NULL) {
                            break;
                        }
                        Handle_DeviceMatchingCallback(NULL, kIOReturnSuccess, gHidManager, values[i]);
                    }
                    free(values);
                }
            }
            CFRelease(devices);
        }
    }
}



static void RetrySetup(CFRunLoopTimerRef timer, void *info) {
    gSetupRetryTimer = NULL;
    fprintf(stderr, "%s: retrying HID setup (%d/%d)\n", __PRETTY_FUNCTION__, gSetupRetryCount, kMaxSetupRetries);
    OpenHIDManager(gTouchManager); // a working connection cancels further retries
}

static void ScheduleSetupRetry(void) {
    if (gSetupRetryTimer != NULL || gSetupRetryCount >= kMaxSetupRetries) {
        return;
    }
    gSetupRetryCount++;
    gSetupRetryTimer = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + kSetupRetryInterval,
                                            0, 0, 0, RetrySetup, NULL);
    CFRunLoopAddTimer(CFRunLoopGetMain(), gSetupRetryTimer, kCFRunLoopCommonModes);
    CFRelease(gSetupRetryTimer); // the run loop keeps it until it fires
}

static void CancelSetupRetry(void) {
    if (gSetupRetryTimer != NULL) {
        CFRunLoopTimerInvalidate(gSetupRetryTimer);
        gSetupRetryTimer = NULL;
    }
    gSetupRetryCount = 0;
}

void CloseHIDManager(void) {
    CancelSetupRetry();
    TearDownHIDManager();
}

static void TearDownHIDManager(void) {
    if (gQueue != NULL) {
        IOHIDQueueUnscheduleFromRunLoop(gQueue, gRunLoopRef, kCFRunLoopCommonModes);
        IOHIDQueueStop(gQueue);
        CFRelease(gQueue);
        gQueue = NULL;
    }

    if (gHidManager != NULL) {
        IOHIDManagerUnscheduleFromRunLoop(gHidManager, gRunLoopRef, kCFRunLoopCommonModes);
        IOHIDManagerClose(gHidManager, kIOHIDOptionsTypeNone);
        CFRelease(gHidManager);
        gHidManager = NULL;
    }

    if (gTouchCollectionElements != NULL) {
        CFRelease(gTouchCollectionElements);
        gTouchCollectionElements = NULL;
    }
    if (gContactIdentifiers != NULL) {
        CFRelease(gContactIdentifiers);
        gContactIdentifiers = NULL;
    }
    if (gStoredInputValues != NULL) {
        CFRelease(gStoredInputValues);
        gStoredInputValues = NULL;
    }

    StopCertificationRead();
    gAreElementRefsSet = 0;
    gTouchscreenCollectionFound = FALSE;
    gContactCount = 1;
    gHybridOffset = 0;
    gTouchscreenUsesHybridMode = FALSE;
}
