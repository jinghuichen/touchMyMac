//
//  HIDInterpreter.c
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#include "HIDInterpreter.h"
#include "TUCTouchInputManager-C.h"

#include <mach/mach_port.h>
#include <mach/mach_time.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDManager.h>

#include <CoreGraphics/CoreGraphics.h>

#pragma mark - Global variables

static void* gTouchManager;

static CFRunLoopRef gRunLoopRef;

static IOHIDManagerRef gHidManager;

IOHIDQueueRef gQueue;


uint8_t gAreElementRefsSet = 0;

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


// Pen (stylus) state. Pens report in their own Digitizer/Pen application collection.
IOHIDElementRef gPenApplicationCollectionElement;

typedef struct {
    CGFloat x;
    CGFloat y;
    Boolean tip;
    Boolean inRange;
    Boolean eraser;
    CGFloat pressure;
    Boolean flushScheduled;
} TUCPenState;

static TUCPenState gPenState = { -1, -1, FALSE, FALSE, FALSE, 0, FALSE };


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
static Boolean IsTouchscreenApplicationCollection(IOHIDElementRef element) {
    return element != NULL
        && IOHIDElementGetType(element) == kIOHIDElementTypeCollection
        && IOHIDElementGetCollectionType(element) == kIOHIDElementCollectionTypeApplication
        && IOHIDElementGetUsagePage(element) == kHIDPage_Digitizer
        && IOHIDElementGetUsage(element) == kHIDUsage_Dig_TouchScreen;
}


/**
 Returns the application collection an element belongs to (or NULL).
 */
static IOHIDElementRef ApplicationCollectionOfElement(IOHIDElementRef element) {
    IOHIDElementRef current = element;
    while (current != NULL) {
        if (IOHIDElementGetType(current) == kIOHIDElementTypeCollection
            && IOHIDElementGetCollectionType(current) == kIOHIDElementCollectionTypeApplication) {
            return current;
        }
        current = IOHIDElementGetParent(current);
    }
    return NULL;
}


/**
 Composite touch devices (e.g. LG CreateBoard) expose mouse, pen, keyboard and touchscreen
 application collections on the same HID interface. Find the touchscreen one explicitly,
 instead of trusting whichever element happens to report first.
 */
static IOHIDElementRef CopyTouchscreenApplicationCollection(IOHIDDeviceRef device) {
    CFArrayRef elements = IOHIDDeviceCopyMatchingElements(device, NULL, kIOHIDOptionsTypeNone);
    if (elements == NULL) {
        return NULL;
    }

    IOHIDElementRef result = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(elements); i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
        if (IsTouchscreenApplicationCollection(element)) {
            result = (IOHIDElementRef)CFRetain(element);
            break;
        }
    }
    CFRelease(elements);
    return result;
}


static Boolean IsElementInTouchscreenCollection(IOHIDElementRef element) {
    IOHIDElementRef application = ApplicationCollectionOfElement(element);
    if (gApplicationCollectionElement != NULL) {
        return application != NULL && CFEqual(application, gApplicationCollectionElement);
    }
    return IsTouchscreenApplicationCollection(application);
}


static IOHIDElementRef CopyPenApplicationCollection(IOHIDDeviceRef device) {
    CFArrayRef elements = IOHIDDeviceCopyMatchingElements(device, NULL, kIOHIDOptionsTypeNone);
    if (elements == NULL) {
        return NULL;
    }
    
    IOHIDElementRef result = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(elements); i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
        if (IOHIDElementGetType(element) == kIOHIDElementTypeCollection
            && IOHIDElementGetCollectionType(element) == kIOHIDElementCollectionTypeApplication
            && IOHIDElementGetUsagePage(element) == kHIDPage_Digitizer
            && IOHIDElementGetUsage(element) == kHIDUsage_Dig_Pen) {
            result = (IOHIDElementRef)CFRetain(element);
            break;
        }
    }
    CFRelease(elements);
    return result;
}


static Boolean IsElementInPenCollection(IOHIDElementRef element) {
    if (gPenApplicationCollectionElement == NULL) {
        return FALSE;
    }
    IOHIDElementRef application = ApplicationCollectionOfElement(element);
    return application != NULL && CFEqual(application, gPenApplicationCollectionElement);
}


static CGFloat NormalizedValue(IOHIDElementRef element, CFIndex value) {
    CGFloat min = (CGFloat)IOHIDElementGetLogicalMin(element);
    CGFloat max = (CGFloat)IOHIDElementGetLogicalMax(element);
    if (max <= min) {
        return 0;
    }
    return ((CGFloat)value - min) / (max - min);
}


static void FlushPenState(void) {
    gPenState.flushScheduled = FALSE;
    static int sFlushLogged = 0;
    if (sFlushLogged < 10) {
        sFlushLogged++;
        printf("[HID] pen flush x=%.3f y=%.3f tip=%d inRange=%d pressure=%.2f\n", gPenState.x, gPenState.y, gPenState.tip, gPenState.inRange, gPenState.pressure);
    }
    if (gPenState.x < 0 || gPenState.y < 0) {
        return;
    }
    TouchInputManagerUpdatePen(gTouchManager, gPenState.x, gPenState.y, gPenState.tip, gPenState.inRange, gPenState.pressure, gPenState.eraser);
}


/**
 Pen values of one report arrive back to back on the run loop. Store them and post a single
 pen update once the whole report has been read.
 */
static void HandlePenValue(IOHIDValueRef hidValue) {
    IOHIDElementRef element = IOHIDValueGetElement(hidValue);
    CFIndex page = IOHIDElementGetUsagePage(element);
    CFIndex usage = IOHIDElementGetUsage(element);
    CFIndex value = IOHIDValueGetIntegerValue(hidValue);
    
    if (page == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_X) {
        gPenState.x = NormalizedValue(element, value);
    } else if (page == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Y) {
        gPenState.y = NormalizedValue(element, value);
    } else if (page == kHIDPage_Digitizer) {
        switch (usage) {
            case kHIDUsage_Dig_TipSwitch:   gPenState.tip = value != 0; break;
            case kHIDUsage_Dig_InRange:     gPenState.inRange = value != 0; break;
            case kHIDUsage_Dig_TipPressure: gPenState.pressure = NormalizedValue(element, value); break;
            case kHIDUsage_Dig_Eraser:
            case kHIDUsage_Dig_Invert:      gPenState.eraser = value != 0; break;
            default: return;
        }
    } else {
        return;
    }
    
    if (!gPenState.flushScheduled) {
        gPenState.flushScheduled = TRUE;
        CFRunLoopPerformBlock(gRunLoopRef, kCFRunLoopCommonModes, ^{
            FlushPenState();
        });
        CFRunLoopWakeUp(gRunLoopRef);
    }
}


/**
 A collection holds one contact if it directly contains an X coordinate and a tip switch or contact identifier.
 */
static Boolean IsContactCollection(IOHIDElementRef collection) {
    CFArrayRef children = IOHIDElementGetChildren(collection);
    if (children == NULL) {
        return FALSE;
    }

    Boolean hasX = FALSE;
    Boolean hasContactInfo = FALSE;
    for (CFIndex i = 0; i < CFArrayGetCount(children); i++) {
        IOHIDElementRef child = (IOHIDElementRef)CFArrayGetValueAtIndex(children, i);
        CFIndex page = IOHIDElementGetUsagePage(child);
        CFIndex usage = IOHIDElementGetUsage(child);
        if (page == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_X) {
            hasX = TRUE;
        } else if (page == kHIDPage_Digitizer
                   && (usage == kHIDUsage_Dig_TipSwitch || usage == kHIDUsage_Dig_ContactIdentifier)) {
            hasContactInfo = TRUE;
        }
    }
    return hasX && hasContactInfo;
}


static void CollectContactCollections(IOHIDElementRef collection, Boolean printTree) {
    CFArrayRef children = IOHIDElementGetChildren(collection);
    if (children == NULL) {
        return;
    }

    for (CFIndex i = 0; i < CFArrayGetCount(children); i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(children, i);
        if (IOHIDElementGetType(element) != kIOHIDElementTypeCollection) {
            continue;
        }

        if (IsContactCollection(element)) {
            CFArrayAppendValue(gTouchCollectionElements, element);
            if (printTree) {
                printf(" > Contact collection (usage %#02lx)\n", (long)IOHIDElementGetUsage(element));
            }
        } else {
            CollectContactCollections(element, printTree);
        }
    }
}


void IdentifyElements(IOHIDElementRef anyElement, Boolean printTree) {

    IOHIDElementRef applicationCollection = gApplicationCollectionElement;
    if (applicationCollection == NULL) {
        applicationCollection = ApplicationCollectionOfElement(anyElement);
        if (applicationCollection == NULL) {
            return;
        }
        gApplicationCollectionElement = (IOHIDElementRef)CFRetain(applicationCollection);
    }
    IOHIDElementType type = IOHIDElementGetType(applicationCollection);

    CFArrayRemoveAllValues(gTouchCollectionElements);
    CollectContactCollections(applicationCollection, printTree);

    if (printTree) {
        printf("# touchscreen collection has %ld contact collections\n", CFArrayGetCount(gTouchCollectionElements));
    }


    CFArrayRef children = IOHIDElementGetChildren(applicationCollection);
    CFIndex numChildren = CFArrayGetCount(children);
    
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
                    CGFloat curr = (CGFloat)value;
                    x = ( (curr - min) / (max - min) ) + min;
                }
                
                else if (usage == kHIDUsage_GD_Y) {
                    CGFloat min = (CGFloat)IOHIDElementGetLogicalMin(element);
                    CGFloat max = (CGFloat)IOHIDElementGetLogicalMax(element);
                    CGFloat curr = (CGFloat)value;
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
    static int sDispatchLogged = 0;
    if (sDispatchLogged < 30) {
        sDispatchLogged++;
        printf("[HID] dispatch contact=%ld x=%.3f y=%.3f tip=%ld valid=%ld\n", (long)contactID, x, y, (long)tipSwitch, (long)isValid);
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

    if (IsElementInPenCollection(elem)) {
        static int sPenLogged = 0;
        if (sPenLogged < 20) {
            sPenLogged++;
            printf("[HID] pen value: ");
            PrintInput(inIOHIDValueRef);
        }
        HandlePenValue(inIOHIDValueRef);
        return;
    }
    
    // Ignore the mouse/keyboard collections that share the interface with the touchscreen.
    static int sIgnoredLogged = 0;
    static int sTouchLogged = 0;
    if (!IsElementInTouchscreenCollection(elem)) {
        if (sIgnoredLogged < 10) {
            sIgnoredLogged++;
            printf("[HID] ignored non-touchscreen value: ");
            PrintInput(inIOHIDValueRef);
        }
        return;
    }
    if (sTouchLogged < 20) {
        sTouchLogged++;
        printf("[HID] touchscreen value: ");
        PrintInput(inIOHIDValueRef);
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








// HID Digitizer usages for Windows-style touch panels (not defined in IOHIDUsageTables.h).
#define kTUCHIDUsage_Dig_DeviceConfiguration 0x0E
#define kTUCHIDUsage_Dig_DeviceMode          0x52
#define kTUCDeviceModeMultiInput             2

/**
 Windows-certified touch panels (e.g. LG CreateBoard) boot in mouse mode and only send
 multi-touch reports after the host writes Device Mode = Multi-Input to the
 Device Configuration feature report. Windows does this automatically; macOS does not.
 */
static void EnableMultiTouchInputMode(IOHIDDeviceRef device) {
    CFArrayRef elements = IOHIDDeviceCopyMatchingElements(device, NULL, kIOHIDOptionsTypeNone);
    if (elements == NULL) {
        return;
    }
    
    for (CFIndex i = 0; i < CFArrayGetCount(elements); i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
        if (IOHIDElementGetType(element) != kIOHIDElementTypeFeature
            || IOHIDElementGetUsagePage(element) != kHIDPage_Digitizer
            || IOHIDElementGetUsage(element) != kTUCHIDUsage_Dig_DeviceMode) {
            continue;
        }
        
        IOHIDValueRef value = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, mach_absolute_time(), kTUCDeviceModeMultiInput);
        if (value == NULL) {
            continue;
        }
        IOReturn result = IOHIDDeviceSetValue(device, element, value);
        CFRelease(value);
        printf("Set touch Device Mode=%d (report %u): 0x%x\n", kTUCDeviceModeMultiInput, (unsigned)IOHIDElementGetReportID(element), result);
    }
    CFRelease(elements);
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

    gAreElementRefsSet = 0;
    if (gApplicationCollectionElement != NULL) {
        CFRelease(gApplicationCollectionElement);
    }
    gApplicationCollectionElement = CopyTouchscreenApplicationCollection(inIOHIDDeviceRef);
    if (gApplicationCollectionElement != NULL) {
        IdentifyElements(gApplicationCollectionElement, TRUE);
        gAreElementRefsSet = 1;
    }
    if (gPenApplicationCollectionElement != NULL) {
        CFRelease(gPenApplicationCollectionElement);
    }
    gPenApplicationCollectionElement = CopyPenApplicationCollection(inIOHIDDeviceRef);
    printf("Pen collection %s\n", gPenApplicationCollectionElement != NULL ? "found" : "not found");
    EnableMultiTouchInputMode(inIOHIDDeviceRef);

    
    IOHIDQueueRef queue = IOHIDQueueCreate(kCFAllocatorDefault, inIOHIDDeviceRef, 1000, kNilOptions);
    
    if (queue == NULL || CFGetTypeID(queue) != IOHIDQueueGetTypeID()) {
        // Usually means the device could not be opened (e.g. Input Monitoring permission denied).
        fprintf(stderr, "%s: could not create HID queue; check Input Monitoring permission.\n", __PRETTY_FUNCTION__);
        if (queue != NULL) {
            CFRelease(queue);
        }
        return;
    }
    
    IOHIDQueueRegisterValueAvailableCallback(queue, Handle_QueueValueAvailable, NULL);
    IOHIDQueueScheduleWithRunLoop(queue, gRunLoopRef, kCFRunLoopCommonModes);
    IOHIDQueueStart(queue);
    gQueue = queue;
    
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
    if (gApplicationCollectionElement != NULL) {
        CFRelease(gApplicationCollectionElement);
        gApplicationCollectionElement = NULL;
    }
    if (gPenApplicationCollectionElement != NULL) {
        CFRelease(gPenApplicationCollectionElement);
        gPenApplicationCollectionElement = NULL;
    }
    gAreElementRefsSet = 0;
    
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
    // Flush diagnostics line by line even when stdout is redirected to a file.
    setvbuf(stdout, NULL, _IOLBF, 0);
    
    // If Open is called twice within one process, make sure we start clean.
    if (gHidManager != NULL) {
        CloseHIDManager();
    }
    
    // Touch panels that also expose a keyboard collection (e.g. LG CreateBoard) can only be
    // opened with Input Monitoring access. Ask for it so macOS lists/prompts for this build.
    if (IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted) {
        if (!IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)) {
            fprintf(stderr, "%s: Input Monitoring access not granted. Enable TouchMyMac in System Settings > Privacy & Security > Input Monitoring.\n", __PRETTY_FUNCTION__);
        }
    }
    
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
    if (openRes != kIOReturnSuccess) {
        fprintf(stderr, "%s: IOHIDManagerOpen failed: 0x%x\n", __PRETTY_FUNCTION__, openRes);
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



void CloseHIDManager(void) {
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

    if (gApplicationCollectionElement != NULL) {
        CFRelease(gApplicationCollectionElement);
        gApplicationCollectionElement = NULL;
    }
    if (gPenApplicationCollectionElement != NULL) {
        CFRelease(gPenApplicationCollectionElement);
        gPenApplicationCollectionElement = NULL;
    }
    gAreElementRefsSet = 0;
    gContactCount = 1;
    gHybridOffset = 0;
    gTouchscreenUsesHybridMode = FALSE;
}
