//
//  TUCCursorUtilities.m
//  Touch Up Core
//
//  Created by Sebastian Hueber on 11.02.23.
//

#import "TUCCursorUtilities.h"
#import <Carbon/Carbon.h>
#import <unistd.h>

@interface TUCCursorUtilities ()

@property NSInteger cursorClickCount;
@property NSDate *timeOfLastClick;
@property CGPoint locationOfLastClick;

@property BOOL isLeftMouseDown;

@property CGPoint momentumScrollVelocity;
@property CFTimeInterval momentumLastTickTime;
@property (strong) NSTimer *momentumScrollTimer;

@property CGPoint scrollVelocity;
@property CFTimeInterval scrollLastSampleTime;

@property BOOL isMagnifying;
@property CGFloat lastPinchDistance;

@property BOOL isHoldingShortcut;
@property (copy) NSArray<NSDictionary<NSString *, NSNumber *> *> *heldModifierDescriptors;
@property (copy) NSArray<NSNumber *> *heldNonModifierKeyCodes;
@property CGEventFlags heldShortcutFlags;

@end

@implementation TUCCursorUtilities

static const NSTimeInterval kMomentumTickInterval = 1.0 / 60.0;
static const CGFloat kDefaultMomentumVelocityStopThreshold = 5.0;     // px/s
static const CGFloat kDefaultMomentumStartThreshold = 120.0;          // px/s
static const CGFloat kDefaultMomentumDecelerationPerFrame = 0.95;     // 60Hz
static const CGKeyCode kUpArrowKeyCode = 126;
static const CGKeyCode kControlKeyCode = kVK_Control;
static NSString * const kMissionControlAppPath = @"/System/Applications/Mission Control.app";
static NSString * const TUCShortcutDescriptorCodeKey = @"code";
static NSString * const TUCShortcutDescriptorFlagKey = @"flag";
static const useconds_t kShortcutSequenceStepDelayMicroseconds = 30000;

+ (TUCCursorUtilities *)sharedInstance {
    static TUCCursorUtilities *sharedInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!sharedInstance) {
            sharedInstance = [[TUCCursorUtilities alloc] init];
            sharedInstance.isLeftMouseDown = NO;
            sharedInstance.cursorClickCount = 0;
            sharedInstance.timeOfLastClick = [NSDate dateWithTimeIntervalSince1970:0];
            sharedInstance.locationOfLastClick = CGPointZero;
            sharedInstance.scrollLastSampleTime = 0;
            sharedInstance.scrollVelocity = CGPointZero;
            sharedInstance.momentumScrollVelocity = CGPointZero;
            sharedInstance.momentumLastTickTime = 0;
            sharedInstance.momentumScrollEnabled = YES;
            sharedInstance.momentumDecelerationPerFrame = kDefaultMomentumDecelerationPerFrame;
            sharedInstance.momentumVelocityMultiplier = 1.0;
            sharedInstance.momentumStartThreshold = kDefaultMomentumStartThreshold;
            sharedInstance.momentumVelocityStopThreshold = kDefaultMomentumVelocityStopThreshold;
        }
    });
    return sharedInstance;
}





- (CGPoint)currentCursorLocation {
    CGEventRef dummy = CGEventCreate(NULL);
    CGPoint location = CGEventGetLocation(dummy);
    CFRelease(dummy);
    return location;
}

- (BOOL)resolveShortcutToken:(NSString *)token
                     keyCode:(CGKeyCode *)keyCode
                        flag:(CGEventFlags *)flag
                  isModifier:(BOOL *)isModifier {
    NSString *normalized = token.lowercaseString;
    if (normalized.length == 0) {
        return NO;
    }

    if ([normalized isEqualToString:@"cmd"] || [normalized isEqualToString:@"command"] || [normalized isEqualToString:@"⌘"]) {
        *keyCode = kVK_Command;
        *flag = kCGEventFlagMaskCommand;
        *isModifier = YES;
        return YES;
    }
    if ([normalized isEqualToString:@"ctrl"] || [normalized isEqualToString:@"control"] || [normalized isEqualToString:@"⌃"]) {
        *keyCode = kVK_Control;
        *flag = kCGEventFlagMaskControl;
        *isModifier = YES;
        return YES;
    }
    if ([normalized isEqualToString:@"opt"] || [normalized isEqualToString:@"option"] || [normalized isEqualToString:@"alt"] || [normalized isEqualToString:@"⌥"]) {
        *keyCode = kVK_Option;
        *flag = kCGEventFlagMaskAlternate;
        *isModifier = YES;
        return YES;
    }
    if ([normalized isEqualToString:@"shift"] || [normalized isEqualToString:@"⇧"]) {
        *keyCode = kVK_Shift;
        *flag = kCGEventFlagMaskShift;
        *isModifier = YES;
        return YES;
    }
    if ([normalized isEqualToString:@"fn"] || [normalized isEqualToString:@"function"] || [normalized isEqualToString:@"globe"]) {
        *keyCode = kVK_Function;
        *flag = kCGEventFlagMaskSecondaryFn;
        *isModifier = YES;
        return YES;
    }

    *flag = 0;
    *isModifier = NO;

    if ([normalized isEqualToString:@"a"]) { *keyCode = kVK_ANSI_A; return YES; }
    if ([normalized isEqualToString:@"b"]) { *keyCode = kVK_ANSI_B; return YES; }
    if ([normalized isEqualToString:@"c"]) { *keyCode = kVK_ANSI_C; return YES; }
    if ([normalized isEqualToString:@"d"]) { *keyCode = kVK_ANSI_D; return YES; }
    if ([normalized isEqualToString:@"e"]) { *keyCode = kVK_ANSI_E; return YES; }
    if ([normalized isEqualToString:@"f"]) { *keyCode = kVK_ANSI_F; return YES; }
    if ([normalized isEqualToString:@"g"]) { *keyCode = kVK_ANSI_G; return YES; }
    if ([normalized isEqualToString:@"h"]) { *keyCode = kVK_ANSI_H; return YES; }
    if ([normalized isEqualToString:@"i"]) { *keyCode = kVK_ANSI_I; return YES; }
    if ([normalized isEqualToString:@"j"]) { *keyCode = kVK_ANSI_J; return YES; }
    if ([normalized isEqualToString:@"k"]) { *keyCode = kVK_ANSI_K; return YES; }
    if ([normalized isEqualToString:@"l"]) { *keyCode = kVK_ANSI_L; return YES; }
    if ([normalized isEqualToString:@"m"]) { *keyCode = kVK_ANSI_M; return YES; }
    if ([normalized isEqualToString:@"n"]) { *keyCode = kVK_ANSI_N; return YES; }
    if ([normalized isEqualToString:@"o"]) { *keyCode = kVK_ANSI_O; return YES; }
    if ([normalized isEqualToString:@"p"]) { *keyCode = kVK_ANSI_P; return YES; }
    if ([normalized isEqualToString:@"q"]) { *keyCode = kVK_ANSI_Q; return YES; }
    if ([normalized isEqualToString:@"r"]) { *keyCode = kVK_ANSI_R; return YES; }
    if ([normalized isEqualToString:@"s"]) { *keyCode = kVK_ANSI_S; return YES; }
    if ([normalized isEqualToString:@"t"]) { *keyCode = kVK_ANSI_T; return YES; }
    if ([normalized isEqualToString:@"u"]) { *keyCode = kVK_ANSI_U; return YES; }
    if ([normalized isEqualToString:@"v"]) { *keyCode = kVK_ANSI_V; return YES; }
    if ([normalized isEqualToString:@"w"]) { *keyCode = kVK_ANSI_W; return YES; }
    if ([normalized isEqualToString:@"x"]) { *keyCode = kVK_ANSI_X; return YES; }
    if ([normalized isEqualToString:@"y"]) { *keyCode = kVK_ANSI_Y; return YES; }
    if ([normalized isEqualToString:@"z"]) { *keyCode = kVK_ANSI_Z; return YES; }
    if ([normalized isEqualToString:@"0"]) { *keyCode = kVK_ANSI_0; return YES; }
    if ([normalized isEqualToString:@"1"]) { *keyCode = kVK_ANSI_1; return YES; }
    if ([normalized isEqualToString:@"2"]) { *keyCode = kVK_ANSI_2; return YES; }
    if ([normalized isEqualToString:@"3"]) { *keyCode = kVK_ANSI_3; return YES; }
    if ([normalized isEqualToString:@"4"]) { *keyCode = kVK_ANSI_4; return YES; }
    if ([normalized isEqualToString:@"5"]) { *keyCode = kVK_ANSI_5; return YES; }
    if ([normalized isEqualToString:@"6"]) { *keyCode = kVK_ANSI_6; return YES; }
    if ([normalized isEqualToString:@"7"]) { *keyCode = kVK_ANSI_7; return YES; }
    if ([normalized isEqualToString:@"8"]) { *keyCode = kVK_ANSI_8; return YES; }
    if ([normalized isEqualToString:@"9"]) { *keyCode = kVK_ANSI_9; return YES; }
    if ([normalized isEqualToString:@"delete"] || [normalized isEqualToString:@"backspace"]) { *keyCode = kVK_Delete; return YES; }
    if ([normalized isEqualToString:@"forwarddelete"]) { *keyCode = kVK_ForwardDelete; return YES; }
    if ([normalized isEqualToString:@"return"]) { *keyCode = kVK_Return; return YES; }
    if ([normalized isEqualToString:@"enter"]) { *keyCode = kVK_ANSI_KeypadEnter; return YES; }
    if ([normalized isEqualToString:@"space"]) { *keyCode = kVK_Space; return YES; }
    if ([normalized isEqualToString:@"tab"]) { *keyCode = kVK_Tab; return YES; }
    if ([normalized isEqualToString:@"grave"] || [normalized isEqualToString:@"backtick"]) { *keyCode = kVK_ANSI_Grave; return YES; }
    if ([normalized isEqualToString:@"hyphen"] || [normalized isEqualToString:@"minus"]) { *keyCode = kVK_ANSI_Minus; return YES; }
    if ([normalized isEqualToString:@"equal"] || [normalized isEqualToString:@"equals"]) { *keyCode = kVK_ANSI_Equal; return YES; }
    if ([normalized isEqualToString:@"leftbracket"] || [normalized isEqualToString:@"["]) { *keyCode = kVK_ANSI_LeftBracket; return YES; }
    if ([normalized isEqualToString:@"rightbracket"] || [normalized isEqualToString:@"]"]) { *keyCode = kVK_ANSI_RightBracket; return YES; }
    if ([normalized isEqualToString:@"backslash"]) { *keyCode = kVK_ANSI_Backslash; return YES; }
    if ([normalized isEqualToString:@"semicolon"]) { *keyCode = kVK_ANSI_Semicolon; return YES; }
    if ([normalized isEqualToString:@"quote"] || [normalized isEqualToString:@"apostrophe"]) { *keyCode = kVK_ANSI_Quote; return YES; }
    if ([normalized isEqualToString:@"comma"]) { *keyCode = kVK_ANSI_Comma; return YES; }
    if ([normalized isEqualToString:@"period"] || [normalized isEqualToString:@"dot"]) { *keyCode = kVK_ANSI_Period; return YES; }
    if ([normalized isEqualToString:@"slash"]) { *keyCode = kVK_ANSI_Slash; return YES; }
    if ([normalized isEqualToString:@"escape"] || [normalized isEqualToString:@"esc"]) { *keyCode = kVK_Escape; return YES; }
    if ([normalized isEqualToString:@"left"]) { *keyCode = kVK_LeftArrow; return YES; }
    if ([normalized isEqualToString:@"right"]) { *keyCode = kVK_RightArrow; return YES; }
    if ([normalized isEqualToString:@"up"]) { *keyCode = kVK_UpArrow; return YES; }
    if ([normalized isEqualToString:@"down"]) { *keyCode = kVK_DownArrow; return YES; }
    if ([normalized isEqualToString:@"home"]) { *keyCode = kVK_Home; return YES; }
    if ([normalized isEqualToString:@"end"]) { *keyCode = kVK_End; return YES; }
    if ([normalized isEqualToString:@"pageup"]) { *keyCode = kVK_PageUp; return YES; }
    if ([normalized isEqualToString:@"pagedown"]) { *keyCode = kVK_PageDown; return YES; }
    if ([normalized isEqualToString:@"f1"]) { *keyCode = kVK_F1; return YES; }
    if ([normalized isEqualToString:@"f2"]) { *keyCode = kVK_F2; return YES; }
    if ([normalized isEqualToString:@"f3"]) { *keyCode = kVK_F3; return YES; }
    if ([normalized isEqualToString:@"f4"]) { *keyCode = kVK_F4; return YES; }
    if ([normalized isEqualToString:@"f5"]) { *keyCode = kVK_F5; return YES; }
    if ([normalized isEqualToString:@"f6"]) { *keyCode = kVK_F6; return YES; }
    if ([normalized isEqualToString:@"f7"]) { *keyCode = kVK_F7; return YES; }
    if ([normalized isEqualToString:@"f8"]) { *keyCode = kVK_F8; return YES; }
    if ([normalized isEqualToString:@"f9"]) { *keyCode = kVK_F9; return YES; }
    if ([normalized isEqualToString:@"f10"]) { *keyCode = kVK_F10; return YES; }
    if ([normalized isEqualToString:@"f11"]) { *keyCode = kVK_F11; return YES; }
    if ([normalized isEqualToString:@"f12"]) { *keyCode = kVK_F12; return YES; }

    return NO;
}

- (nullable NSDictionary<NSString *, id> *)parseShortcutChordSpec:(NSString *)shortcutSpec {
    NSString *trimmed = [shortcutSpec stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return nil;
    }

    NSArray<NSString *> *parts = [trimmed componentsSeparatedByString:@"+"];
    NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *modifierDescriptors = [NSMutableArray array];
    NSMutableArray<NSNumber *> *nonModifierKeyCodes = [NSMutableArray array];
    CGEventFlags flags = 0;

    for (NSString *part in parts) {
        NSString *token = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        CGKeyCode keyCode = 0;
        CGEventFlags tokenFlag = 0;
        BOOL isModifier = NO;
        if (![self resolveShortcutToken:token keyCode:&keyCode flag:&tokenFlag isModifier:&isModifier]) {
            return nil;
        }

        if (isModifier) {
            [modifierDescriptors addObject:@{
                TUCShortcutDescriptorCodeKey: @(keyCode),
                TUCShortcutDescriptorFlagKey: @(tokenFlag)
            }];
            flags |= tokenFlag;
        } else {
            [nonModifierKeyCodes addObject:@(keyCode)];
        }
    }

    return @{
        @"modifiers": modifierDescriptors,
        @"nonModifiers": nonModifierKeyCodes,
        @"flags": @(flags)
    };
}

- (void)postKeyboardEventForKeyCode:(CGKeyCode)keyCode
                             keyDown:(BOOL)keyDown
                               flags:(CGEventFlags)flags {
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, keyCode, keyDown);
    if (event == NULL) {
        return;
    }
    CGEventSetFlags(event, flags);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

- (void)pressAndReleaseShortcutChordWithDescriptors:(NSDictionary<NSString *, id> *)descriptors {
    NSArray<NSDictionary<NSString *, NSNumber *> *> *modifierDescriptors = descriptors[@"modifiers"];
    NSArray<NSNumber *> *nonModifierKeyCodes = descriptors[@"nonModifiers"];
    CGEventFlags flags = [descriptors[@"flags"] unsignedLongLongValue];

    CGEventFlags currentFlags = 0;
    for (NSDictionary<NSString *, NSNumber *> *descriptor in modifierDescriptors) {
        currentFlags |= descriptor[TUCShortcutDescriptorFlagKey].unsignedLongLongValue;
        [self postKeyboardEventForKeyCode:descriptor[TUCShortcutDescriptorCodeKey].unsignedShortValue
                                  keyDown:YES
                                    flags:currentFlags];
    }

    for (NSNumber *keyCode in nonModifierKeyCodes) {
        [self postKeyboardEventForKeyCode:keyCode.unsignedShortValue keyDown:YES flags:flags];
    }

    for (NSNumber *keyCode in [nonModifierKeyCodes reverseObjectEnumerator]) {
        [self postKeyboardEventForKeyCode:keyCode.unsignedShortValue keyDown:NO flags:flags];
    }

    for (NSDictionary<NSString *, NSNumber *> *descriptor in [modifierDescriptors reverseObjectEnumerator]) {
        CGEventFlags nextFlags = currentFlags & ~descriptor[TUCShortcutDescriptorFlagKey].unsignedLongLongValue;
        [self postKeyboardEventForKeyCode:descriptor[TUCShortcutDescriptorCodeKey].unsignedShortValue
                                  keyDown:NO
                                    flags:nextFlags];
        currentFlags = nextFlags;
    }
}



- (void)moveCursorTo:(CGPoint)aLocation {
    [self cancelMomentumScroll];
    [self stopDraggingCursor];
    
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, aLocation, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 0);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static inline CGFloat TUCLength(CGPoint v) {
    return (CGFloat)sqrt((double)(v.x * v.x + v.y * v.y));
}

static inline CGPoint TUCPointScale(CGPoint p, CGFloat s) {
    return CGPointMake(p.x * s, p.y * s);
}

static inline CGPoint TUCPointLerp(CGPoint a, CGPoint b, CGFloat t) {
    return CGPointMake(a.x + (b.x - a.x) * t,
                       a.y + (b.y - a.y) * t);
}

static inline CGFloat TUCClamp(CGFloat v, CGFloat minV, CGFloat maxV) {
    return v < minV ? minV : (v > maxV ? maxV : v);
}

static inline CFTimeInterval TUCNowSeconds(void) {
    return CACurrentMediaTime();
}

- (void)postScrollTranslation:(CGPoint)translation {
    CGEventRef event = CGEventCreateScrollWheelEvent2(NULL, kCGScrollEventUnitPixel, 2, translation.y, translation.x, 0);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

/**
 integrated double click support: needs checks time between clicks and spatial distance
 */
- (void)performClickAt:(CGPoint)aLocation {
    [self updateCursorClickCountWithLocation:aLocation];
    
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, aLocation, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, self.cursorClickCount);
    CGEventPost(kCGHIDEventTap, event);
    CGEventSetType(event, kCGEventLeftMouseUp);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
    
    self.timeOfLastClick = [NSDate date];
    self.locationOfLastClick = aLocation;
}


- (void)updateCursorClickCountWithLocation:(CGPoint)aLocation {
    ++self.cursorClickCount;
    
    NSTimeInterval durationSinceLastClick = [[NSDate date] timeIntervalSinceDate:self.timeOfLastClick];
    
    if (durationSinceLastClick > [NSEvent doubleClickInterval] || self.cursorClickCount == 4) {
        self.cursorClickCount = 1;
    }
    
    else {
        CGFloat dx = aLocation.x - self.locationOfLastClick.x;
        CGFloat dy = aLocation.y - self.locationOfLastClick.y;
        CGFloat distance = (CGFloat)sqrt((double)(dx * dx + dy * dy));
        if (distance > self.doubleClickTolerance) {
            // Only keep counting when the new click lands close enough to the last one.
            self.cursorClickCount = 1;
        }
    }
    
    if (self.cursorClickCount < 1) {
        self.cursorClickCount = 1;
    }
}


- (void)performSecondaryClickAt:(CGPoint)aLocation {
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventRightMouseDown, aLocation, kCGMouseButtonRight);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    CGEventPost(kCGHIDEventTap, event);
    CGEventSetType(event, kCGEventRightMouseUp);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}



- (void)dragCursorTo:(CGPoint)aLocation phase:(NSTouchPhase)phase  {
    if (phase == NSTouchPhaseEnded || phase == NSTouchPhaseCancelled) {
        [self stopDraggingCursor];
        return;
    }
    
    
    if (self.isLeftMouseDown) {
        CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDragged, aLocation, kCGMouseButtonLeft);
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, self.cursorClickCount);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
        
    } else {
        [self moveCursorTo:aLocation];
        [self updateCursorClickCountWithLocation:aLocation];
        CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, aLocation, kCGMouseButtonLeft);
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, self.cursorClickCount);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
        
        self.isLeftMouseDown = YES;
    }
}


- (void)stopDraggingCursor {
    if (self.isLeftMouseDown) {
        CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, [self currentCursorLocation], kCGMouseButtonLeft);
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, self.cursorClickCount);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
        
        self.isLeftMouseDown = NO;
    }
}



- (void)scroll:(CGPoint)translation phase:(NSTouchPhase)phase {
    [self stopDraggingCursor];

    CFTimeInterval now = TUCNowSeconds();

    if (phase == NSTouchPhaseBegan || self.scrollLastSampleTime == 0) {
        [self cancelMomentumScroll];
        self.scrollLastSampleTime = now;
        self.scrollVelocity = CGPointZero;
    }

    // Post the actual scroll event for this frame.
    [self postScrollTranslation:translation];

    if (phase == NSTouchPhaseMoved) {
        CFTimeInterval dt = now - self.scrollLastSampleTime;
        self.scrollLastSampleTime = now;
        if (dt > 0.0005) {
            dt = (CFTimeInterval)TUCClamp((CGFloat)dt, 0.0005f, 0.05f);
            CGPoint instVelocity = TUCPointScale(translation, (CGFloat)(1.0 / dt));
            // Low-pass filter to smooth noisy velocity estimates.
            self.scrollVelocity = TUCPointLerp(self.scrollVelocity, instVelocity, 0.25f);
        }
        return;
    }

    if (phase == NSTouchPhaseEnded || phase == NSTouchPhaseCancelled) {
        self.scrollLastSampleTime = 0;

        CGPoint v0 = self.scrollVelocity;
        self.scrollVelocity = CGPointZero;

        if (!self.momentumScrollEnabled) {
            [self cancelMomentumScroll];
            return;
        }

        if (TUCLength(v0) < self.momentumStartThreshold) {
            [self cancelMomentumScroll];
            return;
        }

        // Start inertial scrolling from the last measured finger velocity.
        [self cancelMomentumScroll];
        self.momentumScrollVelocity = TUCPointScale(v0, self.momentumVelocityMultiplier);
        self.momentumLastTickTime = now;

        self.momentumScrollTimer = [NSTimer timerWithTimeInterval:kMomentumTickInterval
                                                          target:self
                                                        selector:@selector(updateMomentumScroll)
                                                        userInfo:nil
                                                         repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.momentumScrollTimer forMode:NSRunLoopCommonModes];
        return;
    }
}



- (void)updateMomentumScroll {
    if (!self.momentumScrollEnabled) {
        [self cancelMomentumScroll];
        return;
    }

    CFTimeInterval now = TUCNowSeconds();
    CFTimeInterval dt = now - self.momentumLastTickTime;
    self.momentumLastTickTime = now;
    if (dt <= 0) {
        return;
    }

    dt = (CFTimeInterval)TUCClamp((CGFloat)dt, 0.001f, 0.05f);

    CGPoint v = self.momentumScrollVelocity;
    if (fabs(v.x) < self.momentumVelocityStopThreshold && fabs(v.y) < self.momentumVelocityStopThreshold) {
        [self cancelMomentumScroll];
        return;
    }

    CGPoint translation = TUCPointScale(v, (CGFloat)dt);
    [self postScrollTranslation:translation];

    // Exponential decay tuned for ~60Hz.
    CGFloat frames = (CGFloat)(dt / kMomentumTickInterval);
    CGFloat decay = (CGFloat)pow(self.momentumDecelerationPerFrame, frames);
    self.momentumScrollVelocity = TUCPointScale(v, decay);
}



- (void)cancelMomentumScroll {
    if (self.momentumScrollTimer != nil) {
        [self.momentumScrollTimer invalidate];
        self.momentumScrollTimer = nil;
    }
    self.momentumScrollVelocity = CGPointZero;
    self.momentumLastTickTime = 0;
    self.scrollVelocity = CGPointZero;
    self.scrollLastSampleTime = 0;
}


- (void)magnify:(CGFloat)magnification phase:(NSTouchPhase)phase {
    [self stopDraggingCursor];
    
    if (phase == NSTouchPhaseMoved && magnification == 0) {
        // no reason to post that
        return;
    }
    
    // start with a valid mouse event, as it has a valid timestamp
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, [self currentCursorLocation], kCGMouseButtonLeft);
    
    CGEventSetType(event, 29); // type gesture
    CGEventSetFlags(event, 0);
    
    CGEventSetDoubleValueField(event, 113, magnification);
    CGEventSetDoubleValueField(event, 114, magnification);
    CGEventSetDoubleValueField(event, 116, magnification);
    CGEventSetDoubleValueField(event, 118, magnification);
    
    // magic
//    CGEventSetIntegerValueField(event, 55, 29); //if more touches on trackapd 30? about concurrent gestures???
    CGEventSetIntegerValueField(event, 50, 248);
    CGEventSetIntegerValueField(event, 101, 4);
    CGEventSetIntegerValueField(event, 110, 8);
    
    
    CGGesturePhase gesturePhase = kCGGesturePhaseEnded;
    if (phase == NSTouchPhaseBegan) {
        gesturePhase = kCGGesturePhaseBegan;
    } else if (phase == NSTouchPhaseMoved || phase == NSTouchPhaseStationary) {
        gesturePhase = kCGGesturePhaseChanged;
    }
    
    CGEventSetIntegerValueField(event, 132, phase);
    
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}


- (void)magnifyLocationA:(CGPoint)p1 locationB:(CGPoint)p2 relativeP1:(CGPoint)r1 relP2:(CGPoint)r2 {
    [self stopDraggingCursor];
    
    NSTouchPhase phase = NSTouchPhaseMoved;
    
    CGFloat dx = r1.x - r2.x;
    CGFloat dy = r1.y - r2.y;
    
    CGFloat distance = sqrt( pow(dx, 2) + pow(dy, 2) );
    CGFloat delta = distance - self.lastPinchDistance;
    
    self.lastPinchDistance = distance;
    
    if (!self.isMagnifying) {
        CGPoint middle = CGPointMake(0.5f * (p1.x + p2.x), 0.5f * (p1.y + p2.y));
        [self moveCursorTo:middle];
        phase = NSTouchPhaseBegan;
        delta = 0;
        self.isMagnifying = YES;
    }
    
    [self magnify:delta * 4 phase:phase];
}


- (void)stopMagnifying {
    if (self.isMagnifying) {
        self.isMagnifying = NO;
        [self magnify:0 phase:NSTouchPhaseEnded];
    }
}

- (void)beginHoldingShortcutSpec:(NSString *)shortcutSpec {
    NSDictionary<NSString *, id> *descriptors = [self parseShortcutChordSpec:shortcutSpec];
    if (descriptors == nil) {
        return;
    }

    if (self.isHoldingShortcut) {
        [self endHeldShortcut];
    }

    NSArray<NSDictionary<NSString *, NSNumber *> *> *modifierDescriptors = descriptors[@"modifiers"];
    NSArray<NSNumber *> *nonModifierKeyCodes = descriptors[@"nonModifiers"];
    CGEventFlags flags = [descriptors[@"flags"] unsignedLongLongValue];

    CGEventFlags currentFlags = 0;
    for (NSDictionary<NSString *, NSNumber *> *descriptor in modifierDescriptors) {
        currentFlags |= descriptor[TUCShortcutDescriptorFlagKey].unsignedLongLongValue;
        [self postKeyboardEventForKeyCode:descriptor[TUCShortcutDescriptorCodeKey].unsignedShortValue
                                  keyDown:YES
                                    flags:currentFlags];
    }

    for (NSNumber *keyCode in nonModifierKeyCodes) {
        [self postKeyboardEventForKeyCode:keyCode.unsignedShortValue keyDown:YES flags:flags];
    }

    self.isHoldingShortcut = YES;
    self.heldModifierDescriptors = modifierDescriptors;
    self.heldNonModifierKeyCodes = nonModifierKeyCodes;
    self.heldShortcutFlags = flags;
}

- (void)endHeldShortcut {
    if (!self.isHoldingShortcut) {
        return;
    }

    for (NSNumber *keyCode in [self.heldNonModifierKeyCodes reverseObjectEnumerator]) {
        [self postKeyboardEventForKeyCode:keyCode.unsignedShortValue
                                  keyDown:NO
                                    flags:self.heldShortcutFlags];
    }

    CGEventFlags currentFlags = self.heldShortcutFlags;
    for (NSDictionary<NSString *, NSNumber *> *descriptor in [self.heldModifierDescriptors reverseObjectEnumerator]) {
        CGEventFlags nextFlags = currentFlags & ~descriptor[TUCShortcutDescriptorFlagKey].unsignedLongLongValue;
        [self postKeyboardEventForKeyCode:descriptor[TUCShortcutDescriptorCodeKey].unsignedShortValue
                                  keyDown:NO
                                    flags:nextFlags];
        currentFlags = nextFlags;
    }

    self.isHoldingShortcut = NO;
    self.heldModifierDescriptors = @[];
    self.heldNonModifierKeyCodes = @[];
    self.heldShortcutFlags = 0;
}

- (void)performShortcutChordSpec:(NSString *)shortcutSpec {
    NSDictionary<NSString *, id> *descriptors = [self parseShortcutChordSpec:shortcutSpec];
    if (descriptors == nil) {
        return;
    }
    [self pressAndReleaseShortcutChordWithDescriptors:descriptors];
}

- (void)performKeyCode:(CGKeyCode)keyCode modifierFlags:(CGEventFlags)flags {
    static const struct { CGEventFlags flag; CGKeyCode keyCode; } modifierKeys[] = {
        { kCGEventFlagMaskControl,   kVK_Control },
        { kCGEventFlagMaskAlternate, kVK_Option },
        { kCGEventFlagMaskShift,     kVK_Shift },
        { kCGEventFlagMaskCommand,   kVK_Command },
    };
    const size_t modifierCount = sizeof(modifierKeys) / sizeof(modifierKeys[0]);

    CGEventFlags currentFlags = 0;
    for (size_t i = 0; i < modifierCount; i++) {
        if (flags & modifierKeys[i].flag) {
            currentFlags |= modifierKeys[i].flag;
            [self postKeyboardEventForKeyCode:modifierKeys[i].keyCode keyDown:YES flags:currentFlags];
        }
    }

    [self postKeyboardEventForKeyCode:keyCode keyDown:YES flags:currentFlags];
    [self postKeyboardEventForKeyCode:keyCode keyDown:NO flags:currentFlags];

    for (size_t i = modifierCount; i-- > 0;) {
        if (flags & modifierKeys[i].flag) {
            currentFlags &= ~modifierKeys[i].flag;
            [self postKeyboardEventForKeyCode:modifierKeys[i].keyCode keyDown:NO flags:currentFlags];
        }
    }
}

- (void)performShortcutSequenceSpec:(NSString *)shortcutSequenceSpec {
    NSString *normalized = [[shortcutSequenceSpec stringByReplacingOccurrencesOfString:@";" withString:@","]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (normalized.length == 0) {
        return;
    }

    NSArray<NSString *> *steps = [normalized componentsSeparatedByString:@","];
    for (NSString *step in steps) {
        NSDictionary<NSString *, id> *descriptors = [self parseShortcutChordSpec:step];
        if (descriptors == nil) {
            return;
        }
        [self pressAndReleaseShortcutChordWithDescriptors:descriptors];
        usleep(kShortcutSequenceStepDelayMicroseconds);
    }
}

- (void)performMissionControl {
    [self cancelMomentumScroll];
    [self stopDraggingCursor];
    [self stopMagnifying];

    NSURL *missionControlURL = [NSURL fileURLWithPath:kMissionControlAppPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:kMissionControlAppPath]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSWorkspace sharedWorkspace] openURL:missionControlURL];
        });
    }

    CGEventRef controlDown = CGEventCreateKeyboardEvent(NULL, kControlKeyCode, true);
    CGEventRef upDown = CGEventCreateKeyboardEvent(NULL, kUpArrowKeyCode, true);
    CGEventRef upUp = CGEventCreateKeyboardEvent(NULL, kUpArrowKeyCode, false);
    CGEventRef controlUp = CGEventCreateKeyboardEvent(NULL, kControlKeyCode, false);

    if (controlDown == NULL || upDown == NULL || upUp == NULL || controlUp == NULL) {
        if (controlDown != NULL) {
            CFRelease(controlDown);
        }
        if (upDown != NULL) {
            CFRelease(upDown);
        }
        if (upUp != NULL) {
            CFRelease(upUp);
        }
        if (controlUp != NULL) {
            CFRelease(controlUp);
        }
        return;
    }

    CGEventSetFlags(controlDown, kCGEventFlagMaskControl);
    CGEventSetFlags(upDown, kCGEventFlagMaskControl);
    CGEventSetFlags(upUp, kCGEventFlagMaskControl);

    CGEventPost(kCGHIDEventTap, controlDown);
    CGEventPost(kCGHIDEventTap, upDown);
    CGEventPost(kCGHIDEventTap, upUp);
    CGEventPost(kCGHIDEventTap, controlUp);

    CFRelease(controlDown);
    CFRelease(upDown);
    CFRelease(upUp);
    CFRelease(controlUp);
}

@end
