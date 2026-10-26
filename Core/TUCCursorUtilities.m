//
//  TUCCursorUtilities.m
//  Touch Up Core
//
//  Created by Sebastian Hueber on 11.02.23.
//

#import "TUCCursorUtilities.h"
#import <Carbon/Carbon.h>
#import <QuartzCore/QuartzCore.h>
#import <unistd.h>

#define kScrollSampleCapacity 32

@interface TUCCursorUtilities ()

@property NSInteger cursorClickCount;
@property NSDate *timeOfLastClick;
@property CGPoint locationOfLastClick;

@property BOOL isLeftMouseDown;

@property BOOL isScrollGestureActive;
@property CGPoint scrollRemainder; // sub-pixel part of the deltas, carried into the next event
@property CGPoint fingerScrollPosition; // total finger travel in this scroll gesture
// Adaptive smoothing of the finger path (see `filterFingerPosition:at:`).
@property CGPoint filteredFingerPosition;
@property CGPoint filteredFingerVelocity;
@property CGPoint lastRawFingerPosition;
@property CFTimeInterval filterLastTime;
@property CGPoint scrollOutputPosition; // total travel already posted
// The two latest finger reports, used to resample the finger path at display frame times.
@property CFTimeInterval scrollPathTime0;
@property CFTimeInterval scrollPathTime1;
@property CGPoint scrollPathPosition0;
@property CGPoint scrollPathPosition1;
@property CFTimeInterval reportInterval; // running estimate of the time between touch reports

@property BOOL isMomentumActive;
@property CGPoint momentumScrollVelocity;
@property CFTimeInterval momentumLastTickTime;

@property (strong, nullable) id frameDriver; // CADisplayLink, or NSTimer before macOS 14

@property BOOL isMagnifying;
@property CGFloat lastPinchDistance;

@property BOOL isHoldingShortcut;
@property (copy) NSArray<NSDictionary<NSString *, NSNumber *> *> *heldModifierDescriptors;
@property (copy) NSArray<NSNumber *> *heldNonModifierKeyCodes;
@property CGEventFlags heldShortcutFlags;

@end

@implementation TUCCursorUtilities {
    // Recent finger movement, used to measure the velocity at liftoff.
    CFTimeInterval _scrollSampleTimes[kScrollSampleCapacity];
    CGPoint _scrollSampleDeltas[kScrollSampleCapacity];
    NSInteger _scrollSampleCount;
}

static const NSTimeInterval kMomentumTickInterval = 1.0 / 60.0; // the "frame" that deceleration settings refer to
static const NSTimeInterval kFallbackFrameInterval = 1.0 / 120.0;
static const CFTimeInterval kDefaultReportInterval = 1.0 / 100.0;
// One Euro filter settings for the finger path: cutoff frequency at rest (Hz), how fast the cutoff
// rises with finger speed (Hz per px/s), and the cutoff used to smooth the speed estimate itself.
static const CGFloat kScrollFilterMinCutoff = 3.0;
static const CGFloat kScrollFilterBeta = 0.03;
static const CGFloat kScrollFilterSpeedCutoff = 1.0;
static const CFTimeInterval kScrollVelocityWindow = 0.08; // seconds of movement that determine the fling velocity
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
            sharedInstance.reportInterval = kDefaultReportInterval;
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

static inline CGPoint TUCPointAdd(CGPoint a, CGPoint b) {
    return CGPointMake(a.x + b.x, a.y + b.y);
}

static inline CGPoint TUCPointSubtract(CGPoint a, CGPoint b) {
    return CGPointMake(a.x - b.x, a.y - b.y);
}

static inline CGPoint TUCPointScale(CGPoint p, CGFloat s) {
    return CGPointMake(p.x * s, p.y * s);
}

static inline CGFloat TUCClamp(CGFloat v, CGFloat minV, CGFloat maxV) {
    return v < minV ? minV : (v > maxV ? maxV : v);
}

/// Exponential smoothing factor for a low-pass filter with the given cutoff frequency (Hz).
static inline CGFloat TUCSmoothingFactor(CFTimeInterval dt, CGFloat cutoff) {
    CGFloat tau = (CGFloat)(1.0 / (2.0 * M_PI * cutoff));
    return (CGFloat)(1.0 / (1.0 + tau / dt));
}

static inline CFTimeInterval TUCNowSeconds(void) {
    return CACurrentMediaTime();
}

- (void)postScrollDelta:(CGPoint)delta scrollPhase:(CGScrollPhase)scrollPhase momentumPhase:(CGMomentumScrollPhase)momentumPhase {
    // Scroll events carry whole pixels. Carry the remainder forward instead of truncating it,
    // otherwise slow drags and the tail of inertia lose distance and stutter.
    CGPoint total = CGPointMake(self.scrollRemainder.x + delta.x, self.scrollRemainder.y + delta.y);
    int32_t dx = (int32_t)trunc(total.x);
    int32_t dy = (int32_t)trunc(total.y);
    self.scrollRemainder = CGPointMake(total.x - dx, total.y - dy);

    BOOL isPhaseChange = scrollPhase == kCGScrollPhaseBegan || scrollPhase == kCGScrollPhaseEnded
        || momentumPhase == kCGMomentumScrollPhaseBegin || momentumPhase == kCGMomentumScrollPhaseEnd;
    if (dx == 0 && dy == 0 && !isPhaseChange) {
        return;
    }

    CGEventRef event = CGEventCreateScrollWheelEvent2(NULL, kCGScrollEventUnitPixel, 2, dy, dx, 0);
    if (event == NULL) {
        return;
    }
    // Phases make apps treat this like trackpad scrolling: smooth, with rubber banding at the edges.
    CGEventSetIntegerValueField(event, kCGScrollWheelEventScrollPhase, scrollPhase);
    CGEventSetIntegerValueField(event, kCGScrollWheelEventMomentumPhase, momentumPhase);
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
    BOOL isEnding = phase == NSTouchPhaseEnded || phase == NSTouchPhaseCancelled;

    if (!self.isScrollGestureActive) {
        [self cancelMomentumScroll];
        self.isScrollGestureActive = YES;
        self.scrollRemainder = CGPointZero;
        _scrollSampleCount = 0;
        self.fingerScrollPosition = translation;
        self.filteredFingerPosition = translation;
        self.filteredFingerVelocity = CGPointZero;
        self.lastRawFingerPosition = translation;
        self.filterLastTime = now;
        self.scrollOutputPosition = translation;
        self.scrollPathTime0 = now;
        self.scrollPathTime1 = now;
        self.scrollPathPosition0 = translation;
        self.scrollPathPosition1 = translation;
        [self postScrollDelta:translation scrollPhase:kCGScrollPhaseBegan momentumPhase:kCGMomentumScrollPhaseNone];
        [self startFrameDriver];
    } else {
        // Posted on the next display frames by `advanceScrollOutput`, not right away.
        self.fingerScrollPosition = TUCPointAdd(self.fingerScrollPosition, translation);
        [self appendScrollPathPosition:[self filterFingerPosition:self.fingerScrollPosition at:now] at:now];
    }
    // Stationary frames record zero movement, so a finger that stops before lifting doesn't fling.
    // A movement-free liftoff is skipped: on screens without liftoff reports it arrives only after a
    // timeout and would otherwise hide the real release velocity.
    if (!isEnding || !CGPointEqualToPoint(translation, CGPointZero)) {
        [self recordScrollSample:translation at:now];
    }

    if (!isEnding) {
        return;
    }

    [self endScrollGesture];

    CGPoint velocity = [self releaseVelocity];
    if (!self.momentumScrollEnabled || phase == NSTouchPhaseCancelled || TUCLength(velocity) < self.momentumStartThreshold) {
        return;
    }
    [self startMomentumWithVelocity:TUCPointScale(velocity, self.momentumVelocityMultiplier) at:now];
}

- (void)endScrollGesture {
    if (!self.isScrollGestureActive) {
        return;
    }
    // Catch up with the (smoothed) finger, then end.
    [self postScrollDelta:TUCPointSubtract(self.scrollPathPosition1, self.scrollOutputPosition)
              scrollPhase:kCGScrollPhaseChanged
            momentumPhase:kCGMomentumScrollPhaseNone];
    self.scrollOutputPosition = self.scrollPathPosition1;
    [self postScrollDelta:CGPointZero scrollPhase:kCGScrollPhaseEnded momentumPhase:kCGMomentumScrollPhaseNone];
    self.isScrollGestureActive = NO;
}

/**
 Touch coordinates jitter by a fraction of a millimetre. When the finger moves slowly that jitter is as
 large as the movement itself, so the content would step back and forth. A One Euro filter (Casiez et al.,
 CHI 2012) smooths strongly at low speed and barely at high speed, where lag would be noticeable.
 */
- (CGPoint)filterFingerPosition:(CGPoint)raw at:(CFTimeInterval)time {
    CFTimeInterval dt = (CFTimeInterval)TUCClamp((CGFloat)(time - self.filterLastTime), 0.001f, 0.05f);
    self.filterLastTime = time;

    CGPoint rawVelocity = TUCPointScale(TUCPointSubtract(raw, self.lastRawFingerPosition), (CGFloat)(1.0 / dt));
    self.lastRawFingerPosition = raw;
    CGFloat speedFactor = TUCSmoothingFactor(dt, kScrollFilterSpeedCutoff);
    self.filteredFingerVelocity = TUCPointAdd(self.filteredFingerVelocity,
                                              TUCPointScale(TUCPointSubtract(rawVelocity, self.filteredFingerVelocity), speedFactor));

    CGFloat cutoff = kScrollFilterMinCutoff + kScrollFilterBeta * TUCLength(self.filteredFingerVelocity);
    CGFloat factor = TUCSmoothingFactor(dt, cutoff);
    self.filteredFingerPosition = TUCPointAdd(self.filteredFingerPosition,
                                              TUCPointScale(TUCPointSubtract(raw, self.filteredFingerPosition), factor));
    return self.filteredFingerPosition;
}

- (void)appendScrollPathPosition:(CGPoint)position at:(CFTimeInterval)time {
    CFTimeInterval interval = time - self.scrollPathTime1;
    if (interval > 0.002 && interval < 0.05) {
        self.reportInterval = self.reportInterval * 0.8 + interval * 0.2;
    }
    self.scrollPathTime0 = self.scrollPathTime1;
    self.scrollPathPosition0 = self.scrollPathPosition1;
    self.scrollPathTime1 = time;
    self.scrollPathPosition1 = position;
}

- (CGPoint)scrollPathPositionAt:(CFTimeInterval)time {
    if (time >= self.scrollPathTime1) {
        return self.scrollPathPosition1;
    }
    CFTimeInterval span = self.scrollPathTime1 - self.scrollPathTime0;
    if (time <= self.scrollPathTime0 || span <= 0) {
        return self.scrollPathPosition0;
    }
    CGFloat t = (CGFloat)((time - self.scrollPathTime0) / span);
    CGPoint p0 = self.scrollPathPosition0;
    CGPoint p1 = self.scrollPathPosition1;
    return CGPointMake(p0.x + (p1.x - p0.x) * t, p0.y + (p1.y - p0.y) * t);
}

/**
 Touch reports and display frames run at different rates, so posting each report as it arrives moves
 the content unevenly from frame to frame. Instead, each frame shows where the finger was one report
 interval ago, interpolated between the two latest reports, which moves evenly at the cost of that delay.
 */
- (void)advanceScrollOutput {
    CGPoint target = [self scrollPathPositionAt:TUCNowSeconds() - self.reportInterval];
    CGPoint delta = TUCPointSubtract(target, self.scrollOutputPosition);
    self.scrollOutputPosition = target;
    [self postScrollDelta:delta scrollPhase:kCGScrollPhaseChanged momentumPhase:kCGMomentumScrollPhaseNone];
}

- (void)recordScrollSample:(CGPoint)delta at:(CFTimeInterval)time {
    if (_scrollSampleCount == kScrollSampleCapacity) {
        memmove(_scrollSampleTimes, _scrollSampleTimes + 1, sizeof(CFTimeInterval) * (kScrollSampleCapacity - 1));
        memmove(_scrollSampleDeltas, _scrollSampleDeltas + 1, sizeof(CGPoint) * (kScrollSampleCapacity - 1));
        _scrollSampleCount -= 1;
    }
    _scrollSampleTimes[_scrollSampleCount] = time;
    _scrollSampleDeltas[_scrollSampleCount] = delta;
    _scrollSampleCount += 1;
}

/**
 Average velocity (px/s) over the last `kScrollVelocityWindow` of samples. Measured from the last sample
 rather than from now, because screens that don't report liftoff deliver it only after a timeout.
 */
- (CGPoint)releaseVelocity {
    if (_scrollSampleCount < 2) {
        return CGPointZero;
    }

    CFTimeInterval lastTime = _scrollSampleTimes[_scrollSampleCount - 1];
    NSInteger first = _scrollSampleCount - 1;
    while (first > 0 && lastTime - _scrollSampleTimes[first - 1] <= kScrollVelocityWindow) {
        first -= 1;
    }

    CFTimeInterval span = lastTime - _scrollSampleTimes[first];
    if (span < 0.005) {
        return CGPointZero;
    }

    // Each delta covers the time since the previous sample, so the first sample's own delta is outside the span.
    CGPoint distance = CGPointZero;
    for (NSInteger i = first + 1; i < _scrollSampleCount; i++) {
        distance.x += _scrollSampleDeltas[i].x;
        distance.y += _scrollSampleDeltas[i].y;
    }
    return TUCPointScale(distance, (CGFloat)(1.0 / span));
}


#pragma mark Inertia

- (BOOL)isMomentumScrolling {
    return self.isMomentumActive;
}

- (void)startMomentumWithVelocity:(CGPoint)velocity at:(CFTimeInterval)now {
    [self cancelMomentumScroll];

    self.isMomentumActive = YES;
    self.momentumScrollVelocity = velocity;
    self.momentumLastTickTime = now;
    [self postScrollDelta:CGPointZero scrollPhase:0 momentumPhase:kCGMomentumScrollPhaseBegin];
    [self startFrameDriver];
}

- (void)advanceMomentum {
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

    [self postScrollDelta:TUCPointScale(v, (CGFloat)dt) scrollPhase:0 momentumPhase:kCGMomentumScrollPhaseContinue];

    // Exponential decay, expressed per 60Hz frame so the setting means the same at any refresh rate.
    CGFloat decay = (CGFloat)pow(self.momentumDecelerationPerFrame, dt / kMomentumTickInterval);
    self.momentumScrollVelocity = TUCPointScale(v, decay);
}

- (void)cancelMomentumScroll {
    if (self.isMomentumActive) {
        self.isMomentumActive = NO;
        // Tell apps the inertia is over, e.g. when a new touch stops it.
        [self postScrollDelta:CGPointZero scrollPhase:0 momentumPhase:kCGMomentumScrollPhaseEnd];
    }
    self.momentumScrollVelocity = CGPointZero;
    self.momentumLastTickTime = 0;
}


#pragma mark Display Frames

/**
 Finger scrolling and inertia both post one step per display frame, driven from the refresh
 of the screen the cursor (and so the touch) is on. The driver stops once neither is running.
 */
- (void)startFrameDriver {
    if (self.frameDriver != nil) {
        return;
    }

    if (@available(macOS 14.0, *)) {
        NSScreen *screen = [self screenUnderCursor] ?: [NSScreen mainScreen];
        CADisplayLink *displayLink = [screen displayLinkWithTarget:self selector:@selector(frameTick:)];
        [displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        self.frameDriver = displayLink;
    } else {
        NSTimer *timer = [NSTimer timerWithTimeInterval:kFallbackFrameInterval
                                                 target:self
                                               selector:@selector(frameTick:)
                                               userInfo:nil
                                                repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        self.frameDriver = timer;
    }
}

- (void)frameTick:(id)sender {
    if (self.isScrollGestureActive) {
        [self advanceScrollOutput];
    } else if (self.isMomentumActive) {
        [self advanceMomentum];
    } else {
        [self.frameDriver invalidate];
        self.frameDriver = nil;
    }
}

- (nullable NSScreen *)screenUnderCursor {
    CGPoint cursor = [self currentCursorLocation];
    CGFloat primaryHeight = NSMaxY([[NSScreen screens] firstObject].frame);
    NSPoint cocoaPoint = NSMakePoint(cursor.x, primaryHeight - cursor.y);
    for (NSScreen *screen in [NSScreen screens]) {
        if (NSPointInRect(cocoaPoint, screen.frame)) {
            return screen;
        }
    }
    return nil;
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
