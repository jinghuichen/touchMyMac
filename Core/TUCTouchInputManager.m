//
//  TUCTouchInputManager.m
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#import "TUCTouchInputManager.h"

#import "HIDInterpreter.h"
#import "TUCCursorUtilities.h"

@interface TUCTouchInputManager ()

@property NSInteger currentFrameID;

@property (weak, nullable) TUCTouch *cursorTouch;
@property (weak, nullable) TUCTouch *gestureAdditionalTouch;

@property BOOL cursorTouchQualifiedForTap; // if the cursor entered moving state once it can no longer be interpreted as tap
@property BOOL cursorTouchDidHold; //
@property (strong) NSDate *cursorTouchStationarySinceDate;
@property (strong) NSDate *cursorTouchBeganDate;
@property CGPoint cursorTouchStartLocation;
@property TUCCursorAction lastPerformedAction;
@property BOOL suppressEndedPrimaryTouchAction;

@property CGFloat pinchDistance;
@property BOOL hasLastScrollLocation;
@property CGPoint lastScrollLocation;

@property TUCCursorGesture identifiedMultitouchGesture;
@property CGPoint threeFingerSwipeStartCentroid;
@property BOOL threeFingerSwipeTriggered;
@property BOOL threeFingerSwipeTracking;
@property CGPoint fourFingerSwipeLeftStartCentroid;
@property BOOL fourFingerSwipeLeftTriggered;
@property BOOL fourFingerSwipeLeftTracking;
@property CGPoint fourFingerSwipeUpStartCentroid;
@property BOOL fourFingerSwipeUpTriggered;
@property BOOL fourFingerSwipeUpTracking;
@property CGPoint fourFingerSwipeDownStartCentroid;
@property BOOL fourFingerSwipeDownTriggered;
@property BOOL fourFingerSwipeDownTracking;
@property CGPoint fiveFingerHoldStartCentroid;
@property BOOL fiveFingerHoldActivated;
@property BOOL fiveFingerHoldTracking;
@property (strong) NSDate *fiveFingerHoldStartDate;
@property NSInteger debugProcessFrameID;
@property NSInteger debugActiveTouchCount;
@property BOOL debugThreeFingerTracking;
@property BOOL debugThreeFingerTriggered;
@property NSInteger debugThreeFingerTouchCount;
@property NSInteger debugThreeFingerUpwardTouchCount;
@property CGFloat debugThreeFingerVerticalTravelMM;
@property CGFloat debugThreeFingerHorizontalTravelMM;

@property (strong) NSTimer *touchInactivityTimer;

// Pen state and palm rejection: finger contacts are ignored while a pen is near the screen.
@property BOOL penIsDown;
@property BOOL penInRange;
@property (strong, nullable) NSDate *penLastActiveDate;
@property (strong) NSMutableSet<NSNumber *> *penSuppressedContactIDs;
@property (strong, nullable) NSTimer *penUpDebounceTimer;
@property CGPoint penLastLocation;
@property NSInteger penStrokeDragCount;
@property (nonatomic) CFMachPortRef nativePenEventTap;
@property (nonatomic) CFRunLoopSourceRef nativePenEventTapSource;
@property NSInteger nativePenEventsDropped;

@end


@implementation TUCTouchInputManager

@synthesize scrollInertiaEnabled = _scrollInertiaEnabled;
@synthesize scrollInertiaDecelerationPerFrame = _scrollInertiaDecelerationPerFrame;
@synthesize scrollInertiaVelocityMultiplier = _scrollInertiaVelocityMultiplier;

static const CGFloat kStationaryThresholdMM = 0.1f;
static const CGFloat kTapCancelDistanceMM = 4.0f;
static const CGFloat kTapFallbackDistanceMM = 5.0f;
static const NSTimeInterval kTapFallbackDuration = 0.25;
static const CGFloat kScrollReanchorDistanceMM = 25.0f;
static const NSTimeInterval kTouchInactivityTimeout = 0.12;
static const CGFloat kThreeFingerSwipeTriggerTravelMM = 18.0f;
static const CGFloat kThreeFingerSwipeMaxHorizontalTravelMM = 18.0f;
static const CGFloat kThreeFingerSpaceSwipeTriggerTravelMM = 30.0f;
static const CGFloat kThreeFingerSpaceSwipeMaxVerticalTravelMM = 20.0f;
static const CGFloat kFourFingerSwipeTriggerTravelMM = 20.0f;
static const CGFloat kFourFingerSwipeMaxVerticalTravelMM = 18.0f;
static const CGFloat kFourFingerSwipeMaxHorizontalTravelMM = 18.0f;
static const NSTimeInterval kFiveFingerHoldActivationDuration = 0.25;
static const CGFloat kFiveFingerHoldMaxTravelMM = 12.0f;

#pragma mark   Start & Stop

- (void)start {
    
    __weak id weakSelf = self;
    
    // needs to run on main anyway
//    [NSThread detachNewThreadWithBlock:^{
//        [NSThread setThreadPriority:1];
        OpenHIDManager((__bridge void *)(weakSelf));
//    }];
    [self installNativePenEventFilter];

    if (self.touchInactivityTimer == nil) {
        self.touchInactivityTimer = [NSTimer timerWithTimeInterval:0.03
                                                            target:self
                                                          selector:@selector(handleTouchInactivityTimer:)
                                                          userInfo:nil
                                                           repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.touchInactivityTimer forMode:NSRunLoopCommonModes];
    }
    
}

- (void)stop {
    [self removeNativePenEventFilter];
    CloseHIDManager();
    if (self.touchInactivityTimer != nil) {
        [self.touchInactivityTimer invalidate];
        self.touchInactivityTimer = nil;
    }
}


- (void)didConnectTouchscreen {
    [self.delegate touchscreenDidConnect];
}

- (void)didDisconnectTouchscreen {
    [self.delegate touchscreenDidDisconnect];
}



#pragma mark - Reacting to HID Events

- (void)didProcessReport {
    // go through all touches: if the frame is not the latest one, the touch might be old and should be removed.
    
    for (TUCTouch *touch in self.touchSet) {
        
        if (touch.lastUpdated + self.errorResistance < self.currentFrameID) {
            // Some touchscreens don't reliably report liftoff (tip switch off) for the final contact.
            // If a touch disappears from the report stream, treat it as a liftoff so tap/scroll end
            // can still be recognized.
            [touch setIsOnSurface:NO];
            [touch setPhase:NSTouchPhaseEnded];
            [self removeTouch:touch now:NO];
        }
    }
    
    if ([[self activeTouches] count] == 0) {
        [self stopCurrentGesture];
    }
    
    ++self.currentFrameID;
    self.debugProcessFrameID = self.currentFrameID;
    self.debugActiveTouchCount = (NSInteger)[[self activeTouches] count];
    
    [self processTouchesForCursorInput];
    [self.delegate inputDiagnosticsDidChange];
    
}

- (void)handleTouchInactivityTimer:(NSTimer *)timer {
    if (self.touchSet.count == 0) {
        return;
    }

    NSDate *now = [NSDate date];
    BOOL didChange = NO;

    // Iterate over a snapshot, as we may remove touches.
    NSArray<TUCTouch *> *touches = [self.touchSet allObjects];
    for (TUCTouch *touch in touches) {
        if (!touch.isActive) {
            continue;
        }

        NSDate *lastUpdatedAt = touch.lastUpdatedAt;
        if (lastUpdatedAt == nil) {
            continue;
        }

        NSTimeInterval idle = [now timeIntervalSinceDate:lastUpdatedAt];
        if (idle < kTouchInactivityTimeout) {
            continue;
        }

        // If the device stops sending reports on liftoff (common for some touchscreens),
        // synthesize an Ended phase so taps and scroll/drags can terminate.
        [touch setIsOnSurface:NO];
        [touch setPhase:NSTouchPhaseEnded];

        if (self.cursorTouch != nil && touch.uuid == self.cursorTouch.uuid) {
            // Drive the existing gesture state machine to decide between tap/drag/hold&drag.
            [self processTouchesForCursorInput];
        }

        [self removeTouch:touch now:NO];
        didChange = YES;
    }

    if (didChange) {
        [self.delegate touchesDidChange];
    }
}

- (CGFloat)distanceMMFromPoint:(CGPoint)p1 toPoint:(CGPoint)p2 {
    CGFloat relDx = p1.x - p2.x;
    CGFloat relDy = p1.y - p2.y;
    CGFloat relDistance = sqrt(pow(relDx, 2) + pow(relDy, 2));
    return relDistance * [self touchscreen].physicalSize.width;
}

- (CGFloat)cursorTouchDistanceFromStartMM {
    if (self.cursorTouch == nil) {
        return 0;
    }
    return [self distanceMMFromPoint:self.cursorTouch.location toPoint:self.cursorTouchStartLocation];
}

- (void)resetThreeFingerSwipeTracking {
    self.threeFingerSwipeTracking = NO;
    self.threeFingerSwipeTriggered = NO;
    self.threeFingerSwipeStartCentroid = CGPointZero;
    self.debugThreeFingerTracking = NO;
    self.debugThreeFingerTriggered = NO;
    self.debugThreeFingerTouchCount = 0;
    self.debugThreeFingerUpwardTouchCount = 0;
    self.debugThreeFingerVerticalTravelMM = 0;
    self.debugThreeFingerHorizontalTravelMM = 0;
}

- (CGPoint)centroidForTouches:(NSArray<TUCTouch *> *)touches {
    if (touches.count == 0) {
        return CGPointZero;
    }

    CGFloat x = 0;
    CGFloat y = 0;
    for (TUCTouch *touch in touches) {
        x += touch.location.x;
        y += touch.location.y;
    }

    CGFloat count = (CGFloat)touches.count;
    return CGPointMake(x / count, y / count);
}

- (NSInteger)upwardTouchCountForTouches:(NSArray<TUCTouch *> *)touches
                           hasDownward:(BOOL *)hasDownward {
    NSInteger upwardTouches = 0;
    BOOL foundDownward = NO;

    for (TUCTouch *touch in touches) {
        CGPoint trajectory = [touch trajectory];
        if (trajectory.y > 0) {
            foundDownward = YES;
        }
        if (trajectory.y < 0 && fabs(trajectory.y) >= fabs(trajectory.x)) {
            upwardTouches += 1;
        }
    }

    if (hasDownward != NULL) {
        *hasDownward = foundDownward;
    }

    return upwardTouches;
}

- (NSInteger)leftwardTouchCountForTouches:(NSArray<TUCTouch *> *)touches
                              hasRightward:(BOOL *)hasRightward {
    NSInteger leftwardTouches = 0;
    BOOL foundRightward = NO;

    for (TUCTouch *touch in touches) {
        CGPoint trajectory = [touch trajectory];
        if (trajectory.x > 0) {
            foundRightward = YES;
        }
        if (trajectory.x < 0 && fabs(trajectory.x) >= fabs(trajectory.y)) {
            leftwardTouches += 1;
        }
    }

    if (hasRightward != NULL) {
        *hasRightward = foundRightward;
    }

    return leftwardTouches;
}

- (BOOL)isThreeFingerSwipeEnabledInCurrentConfig {
    return self.threeFingerSwipeEnabled;
}

- (BOOL)isFourFingerSwipeLeftEnabledInCurrentConfig {
    return [[self.fourFingerSwipeLeftSequenceSpec stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] > 0;
}

- (BOOL)isFiveFingerHoldEnabledInCurrentConfig {
    return [[self.fiveFingerHoldShortcutSpec stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] > 0;
}

- (void)resetFourFingerSwipeLeftTracking {
    self.fourFingerSwipeLeftTracking = NO;
    self.fourFingerSwipeLeftTriggered = NO;
    self.fourFingerSwipeLeftStartCentroid = CGPointZero;
}

- (void)resetFourFingerSwipeUpTracking {
    self.fourFingerSwipeUpTracking = NO;
    self.fourFingerSwipeUpTriggered = NO;
    self.fourFingerSwipeUpStartCentroid = CGPointZero;
}

- (void)resetFourFingerSwipeDownTracking {
    self.fourFingerSwipeDownTracking = NO;
    self.fourFingerSwipeDownTriggered = NO;
    self.fourFingerSwipeDownStartCentroid = CGPointZero;
}

- (void)resetFiveFingerHoldTracking {
    if (self.fiveFingerHoldActivated) {
        [[TUCCursorUtilities sharedInstance] endHeldShortcut];
    }
    self.fiveFingerHoldTracking = NO;
    self.fiveFingerHoldActivated = NO;
    self.fiveFingerHoldStartCentroid = CGPointZero;
    self.fiveFingerHoldStartDate = nil;
}


- (void)stopCurrentGesture {
    [[TUCCursorUtilities sharedInstance] stopDraggingCursor];
    [[TUCCursorUtilities sharedInstance] stopMagnifying];
    self.hasLastScrollLocation = NO;
    self.lastPerformedAction = TUCCursorActionNone;
    self.suppressEndedPrimaryTouchAction = NO;

    self.identifiedMultitouchGesture = _TUCCursorGestureNone;
    self.gestureAdditionalTouch = nil;
    [self resetThreeFingerSwipeTracking];
    [self resetFourFingerSwipeLeftTracking];
    [self resetFourFingerSwipeUpTracking];
    [self resetFourFingerSwipeDownTracking];
    [self resetFiveFingerHoldTracking];
}



/**
 Most important event handling callback: it posts the events to the system where the touches need to go
 */
- (void)updateTouch:(NSInteger)contactID withLocation:(CGPoint)digitizerPoint onSurface:(BOOL)isOnSurface tooLargeForFinger:(BOOL)confidenceFlag {
    
    // assume that this is an erroneous message!!!
    if (self.ignoreOriginTouches && CGPointEqualToPoint(digitizerPoint, CGPointZero)) {
        return;
    }
    
    // Palm rejection: contacts that touched down while a pen was in use stay ignored until lifted.
    NSNumber *contactKey = @(contactID);
    if ([self.penSuppressedContactIDs containsObject:contactKey]) {
        if (!isOnSurface) {
            [self.penSuppressedContactIDs removeObject:contactKey];
        }
        return;
    }
    if ([self isPenActive] && isOnSurface) {
        NSLog(@"[Pen] ignoring finger contact %ld while pen is active", (long)contactID);
        [self.penSuppressedContactIDs addObject:contactKey];
        return;
    }
    
    CGPoint point = [self convertDigitizerPointToRelativeScreenPoint:digitizerPoint];
    
    BOOL isNewTouch = NO;
    TUCTouch *touch = [self obtainTouchWithID:contactID isNew:&isNewTouch];
    
    if (isNewTouch && (self.cursorTouch == nil || !self.cursorTouch.isActive)) {
        // Always start a clean gesture session for a new primary touch.
        [self stopCurrentGesture];
        
        self.cursorTouch = touch;
        self.cursorTouchQualifiedForTap = YES;
        self.cursorTouchDidHold = NO;
        self.cursorTouchStationarySinceDate = nil;
        self.cursorTouchBeganDate = [NSDate date];
        self.cursorTouchStartLocation = point;
        self.gestureAdditionalTouch = nil;
    }
    
    [touch setLocation: point];
    [touch setIsOnSurface:isOnSurface];
    [touch setConfidenceFlag:confidenceFlag];
    [touch setLastUpdated:self.currentFrameID];
    
    if (!isOnSurface) {
        [touch setPhase: NSTouchPhaseEnded];
        [self removeTouch:touch now:NO];
        [self.delegate touchesDidChange];
        return;
        
    }
    
    if(touch.previousPhase != NSTouchPhaseEnded && !isNewTouch) {
        // update to an existing touch... check if stationary or not
        CGFloat digitizerRelDistance = sqrt(pow(touch.location.x - touch.previousLocation.x, 2) + pow(touch.location.y - touch.previousLocation.y, 2));
        CGFloat screenSize = [self touchscreen].physicalSize.width;
        BOOL isStationary = (digitizerRelDistance * screenSize) < kStationaryThresholdMM;
//        BOOL isStationary = CGPointEqualToPoint(touch.location, touch.previousLocation);
        
        if (touch.uuid == self.cursorTouch.uuid) {
            CGFloat distanceFromStartMM = [self cursorTouchDistanceFromStartMM];
            if (distanceFromStartMM > kTapCancelDistanceMM) {
                self.cursorTouchQualifiedForTap = NO;
            }
            
            if (!isStationary) {
                self.cursorTouchStationarySinceDate = nil;
            } else if (touch.phase !=  NSTouchPhaseStationary) {
                self.cursorTouchStationarySinceDate = [NSDate date];
            }
        }
        
        [touch setPhase:isStationary ? NSTouchPhaseStationary : NSTouchPhaseMoved];
    }
    
    
    [self.delegate touchesDidChange];
    
    return;
}


- (void)updateTouch:(NSInteger)contactID withSize:(CGSize)size azimuth:(CGFloat)azimuth {
    BOOL isNewTouch = NO;
    TUCTouch *touch = [self obtainTouchWithID:contactID isNew:&isNewTouch];
    [touch setLastUpdated:self.currentFrameID];
    
    [touch setSize:size];
    [touch setAzimuth:azimuth];
}



#pragma mark - Mouse Cursor Management



- (void)processTouchesForCursorInput {
    
    if(!self.cursorTouch || !self.postMouseEvents) {
        return;
    }
    
    // Never let finger input (e.g. a resting palm) interfere with a pen stroke.
    if ([self isPenActive]) {
        return;
    }
    
    TUCTouch *cursorTouch = self.cursorTouch;
    
    
    NSArray<TUCTouch *> *touches = [[self activeTouches] allObjects];
    NSTouchPhase phase = cursorTouch.phase;
    
    // Hard guard against a latched multi-touch gesture when contacts go stale.
    if (self.identifiedMultitouchGesture == TUCCursorGesturePinch) {
        BOOL hasTwoTouches = [touches count] >= 2;
        BOOL cursorFresh = cursorTouch.isActive && (cursorTouch.lastUpdated + self.errorResistance >= self.currentFrameID);
        BOOL additionalFresh = self.gestureAdditionalTouch != nil
            && self.gestureAdditionalTouch.isActive
            && (self.gestureAdditionalTouch.lastUpdated + self.errorResistance >= self.currentFrameID);
        
        if (!hasTwoTouches || !cursorFresh || !additionalFresh) {
            self.gestureAdditionalTouch = nil;
            [self stopCurrentGesture];
        }
    }

    if ((![self isFiveFingerHoldEnabledInCurrentConfig] || self.fiveFingerHoldTracking) && [touches count] != 5) {
        [self resetFiveFingerHoldTracking];
    }

    if ([self isFiveFingerHoldEnabledInCurrentConfig] && [touches count] == 5 && [touches containsObject:cursorTouch]) {
        CGPoint centroid = [self centroidForTouches:touches];
        CGSize physicalSize = [self touchscreen].physicalSize;

        if (!self.fiveFingerHoldTracking) {
            self.fiveFingerHoldTracking = YES;
            self.fiveFingerHoldActivated = NO;
            self.fiveFingerHoldStartCentroid = centroid;
            self.fiveFingerHoldStartDate = [NSDate date];
        }

        CGFloat dxMM = (centroid.x - self.fiveFingerHoldStartCentroid.x) * physicalSize.width;
        CGFloat dyMM = (centroid.y - self.fiveFingerHoldStartCentroid.y) * physicalSize.height;
        CGFloat travelMM = (CGFloat)sqrt((double)(dxMM * dxMM + dyMM * dyMM));
        NSTimeInterval holdTime = self.fiveFingerHoldStartDate == nil ? 0 : [[NSDate date] timeIntervalSinceDate:self.fiveFingerHoldStartDate];

        if (!self.fiveFingerHoldActivated && travelMM > kFiveFingerHoldMaxTravelMM) {
            self.fiveFingerHoldStartCentroid = centroid;
            self.fiveFingerHoldStartDate = [NSDate date];
        } else if (!self.fiveFingerHoldActivated && holdTime >= kFiveFingerHoldActivationDuration) {
            [self performMouseEventForGesture:TUCCursorGestureFiveFingerHold];
            self.fiveFingerHoldActivated = YES;
        }

        return;
    }

    if ((![self isFourFingerSwipeLeftEnabledInCurrentConfig] || self.fourFingerSwipeLeftTracking) && [touches count] != 4) {
        [self resetFourFingerSwipeLeftTracking];
    }

    if ((!self.fourFingerSwipeUpKeyboardEnabled || self.fourFingerSwipeUpTracking) && [touches count] != 4) {
        [self resetFourFingerSwipeUpTracking];
    }

    if ((!self.fourFingerSwipeUpKeyboardEnabled || self.fourFingerSwipeDownTracking) && [touches count] != 4) {
        [self resetFourFingerSwipeDownTracking];
    }

    if ([touches count] == 4 && [touches containsObject:cursorTouch]) {
        CGPoint centroid = [self centroidForTouches:touches];
        CGSize physicalSize = [self touchscreen].physicalSize;

        if ([self isFourFingerSwipeLeftEnabledInCurrentConfig] && !self.fourFingerSwipeLeftTracking) {
            self.fourFingerSwipeLeftTracking = YES;
            self.fourFingerSwipeLeftTriggered = NO;
            self.fourFingerSwipeLeftStartCentroid = centroid;
        }

        if (self.fourFingerSwipeUpKeyboardEnabled && !self.fourFingerSwipeUpTracking) {
            self.fourFingerSwipeUpTracking = YES;
            self.fourFingerSwipeUpTriggered = NO;
            self.fourFingerSwipeUpStartCentroid = centroid;
        }

        if (self.fourFingerSwipeUpKeyboardEnabled && !self.fourFingerSwipeDownTracking) {
            self.fourFingerSwipeDownTracking = YES;
            self.fourFingerSwipeDownTriggered = NO;
            self.fourFingerSwipeDownStartCentroid = centroid;
        }

        CGFloat leftHorizontalTravelMM = (self.fourFingerSwipeLeftStartCentroid.x - centroid.x) * physicalSize.width;
        CGFloat leftVerticalTravelMM = fabs((centroid.y - self.fourFingerSwipeLeftStartCentroid.y) * physicalSize.height);
        BOOL shouldTriggerLeft = [self isFourFingerSwipeLeftEnabledInCurrentConfig]
            && leftHorizontalTravelMM >= kFourFingerSwipeTriggerTravelMM
            && leftVerticalTravelMM <= kFourFingerSwipeMaxVerticalTravelMM
            && leftHorizontalTravelMM >= leftVerticalTravelMM;

        CGFloat upVerticalTravelMM = (self.fourFingerSwipeUpStartCentroid.y - centroid.y) * physicalSize.height;
        CGFloat upHorizontalTravelMM = fabs((centroid.x - self.fourFingerSwipeUpStartCentroid.x) * physicalSize.width);
        BOOL shouldTriggerUp = self.fourFingerSwipeUpKeyboardEnabled
            && upVerticalTravelMM >= kFourFingerSwipeTriggerTravelMM
            && upHorizontalTravelMM <= kFourFingerSwipeMaxHorizontalTravelMM
            && upVerticalTravelMM >= upHorizontalTravelMM;

        CGFloat downVerticalTravelMM = (centroid.y - self.fourFingerSwipeDownStartCentroid.y) * physicalSize.height;
        CGFloat downHorizontalTravelMM = fabs((centroid.x - self.fourFingerSwipeDownStartCentroid.x) * physicalSize.width);
        BOOL shouldTriggerDown = self.fourFingerSwipeUpKeyboardEnabled
            && downVerticalTravelMM >= kFourFingerSwipeTriggerTravelMM
            && downHorizontalTravelMM <= kFourFingerSwipeMaxHorizontalTravelMM
            && downVerticalTravelMM >= downHorizontalTravelMM;

        if (!self.fourFingerSwipeUpTriggered && shouldTriggerUp && upVerticalTravelMM >= leftHorizontalTravelMM) {
            self.suppressEndedPrimaryTouchAction = YES;
            [self performMouseEventForGesture:TUCCursorGestureFourFingerSwipeUp];
            self.fourFingerSwipeUpTriggered = YES;
            return;
        }

        if (!self.fourFingerSwipeDownTriggered && shouldTriggerDown
            && downVerticalTravelMM >= leftHorizontalTravelMM) {
            self.suppressEndedPrimaryTouchAction = YES;
            [self performMouseEventForGesture:TUCCursorGestureFourFingerSwipeDown];
            self.fourFingerSwipeDownTriggered = YES;
            return;
        }

        if (!self.fourFingerSwipeLeftTriggered && shouldTriggerLeft) {
            self.suppressEndedPrimaryTouchAction = YES;
            [self performMouseEventForGesture:TUCCursorGestureFourFingerSwipeLeft];
            self.fourFingerSwipeLeftTriggered = YES;
            return;
        }

        if ([self isFourFingerSwipeLeftEnabledInCurrentConfig] || self.fourFingerSwipeUpKeyboardEnabled) {
            return;
        }
    }

    if ((!self.threeFingerSwipeEnabled || self.threeFingerSwipeTracking) && [touches count] != 3) {
        [self resetThreeFingerSwipeTracking];
    }

    if (self.threeFingerSwipeEnabled && [touches count] == 3 && [touches containsObject:cursorTouch]) {
        if (!self.threeFingerSwipeTracking) {
            self.threeFingerSwipeTracking = YES;
            self.threeFingerSwipeTriggered = NO;
            self.threeFingerSwipeStartCentroid = [self centroidForTouches:touches];
            NSLog(@"[3F] tracking started (screen %.0f x %.0f mm)", [self touchscreen].physicalSize.width, [self touchscreen].physicalSize.height);
        }

        CGPoint centroid = [self centroidForTouches:touches];
        CGSize physicalSize = [self touchscreen].physicalSize;
        CGFloat verticalTravelMM = (self.threeFingerSwipeStartCentroid.y - centroid.y) * physicalSize.height;
        CGFloat horizontalTravelMM = fabs((centroid.x - self.threeFingerSwipeStartCentroid.x) * physicalSize.width);

        BOOL hasDownward = NO;
        NSInteger upwardTouchCount = [self upwardTouchCountForTouches:touches hasDownward:&hasDownward];
        BOOL shouldTrigger = !hasDownward
            && upwardTouchCount >= 2
            && verticalTravelMM >= kThreeFingerSwipeTriggerTravelMM
            && horizontalTravelMM <= kThreeFingerSwipeMaxHorizontalTravelMM;

        self.debugThreeFingerTracking = YES;
        self.debugThreeFingerTriggered = self.threeFingerSwipeTriggered;
        self.debugThreeFingerTouchCount = touches.count;
        self.debugThreeFingerUpwardTouchCount = upwardTouchCount;
        self.debugThreeFingerVerticalTravelMM = verticalTravelMM;
        self.debugThreeFingerHorizontalTravelMM = horizontalTravelMM;

        if (!self.threeFingerSwipeTriggered && shouldTrigger) {
            self.suppressEndedPrimaryTouchAction = YES;
            [self performMouseEventForGesture:TUCCursorGestureThreeFingerSwipeUp];
            self.threeFingerSwipeTriggered = YES;
            self.debugThreeFingerTriggered = YES;
        }
        
        // Three-finger horizontal drag switches between Spaces / full-screen apps, like a trackpad.
        CGFloat signedHorizontalTravelMM = (centroid.x - self.threeFingerSwipeStartCentroid.x) * physicalSize.width;
        BOOL shouldSwitchSpace = !self.threeFingerSwipeTriggered
            && fabs(signedHorizontalTravelMM) >= kThreeFingerSpaceSwipeTriggerTravelMM
            && fabs(verticalTravelMM) <= kThreeFingerSpaceSwipeMaxVerticalTravelMM;
        static NSInteger sThreeFingerLogCounter = 0;
        if (!self.threeFingerSwipeTriggered && (sThreeFingerLogCounter++ % 10) == 0) {
            NSLog(@"[3F] horizontal %.1f mm, vertical %.1f mm", signedHorizontalTravelMM, verticalTravelMM);
        }
        if (shouldSwitchSpace) {
            NSLog(@"[3F] switching space %@", signedHorizontalTravelMM < 0 ? @"right" : @"left");
            self.suppressEndedPrimaryTouchAction = YES;
            self.threeFingerSwipeTriggered = YES;
            self.debugThreeFingerTriggered = YES;
            // Fingers moving left reveal the space to the right (natural direction).
            [[TUCCursorUtilities sharedInstance] switchSpaceToRight:(signedHorizontalTravelMM < 0)];
        }

        return;
    }

    if (phase == NSTouchPhaseBegan) {
        [self performMouseEventForGesture:TUCCursorGestureTouchDown];
        return;
    }
    
    if ([self updateCursorTouchHoldStateWithActiveTouchCount:touches.count]) {
        return;
    }
    
    
    else if (phase == NSTouchPhaseStationary) {
        NSTimeInterval holdDuration = 0;
        if (self.cursorTouchStationarySinceDate != nil) {
            holdDuration = [[NSDate date] timeIntervalSinceDate:self.cursorTouchStationarySinceDate];
        }
        if (self.cursorTouchQualifiedForTap && holdDuration > self.holdDuration) {
            // the user left the finger on the screen for the min duration required to produce a hold
            self.cursorTouchDidHold = YES;
        }
        
        [self checkForSecondaryClick];
        
        return;
    }
    
    
    else if (phase == NSTouchPhaseEnded) {
        CGFloat movementMM = [self cursorTouchDistanceFromStartMM];
        NSTimeInterval touchDuration = self.cursorTouchBeganDate == nil ? 0 : [[NSDate date] timeIntervalSinceDate:self.cursorTouchBeganDate];
        BOOL shortTouchWithSmallTravel = touchDuration <= kTapFallbackDuration && movementMM <= kTapFallbackDistanceMM;
        // Only interpret liftoff as a tap when no other fingers are still active.
        BOOL noOtherActiveTouches = touches.count == 0;
        BOOL shouldTreatAsTap = noOtherActiveTouches && (self.cursorTouchQualifiedForTap || shortTouchWithSmallTravel);
        BOOL suppressEndedAction = self.suppressEndedPrimaryTouchAction;
        TUCCursorGesture completedMultitouchGesture = self.identifiedMultitouchGesture;
        
        if (!suppressEndedAction && completedMultitouchGesture == _TUCCursorGestureNone ) {
            if (self.cursorTouchDidHold) {
                [self performMouseEventForGesture:TUCCursorGestureHoldAndDrag];
            } else if (!shouldTreatAsTap) {
                [self performMouseEventForGesture:TUCCursorGestureDrag];
            }
        } else if (!suppressEndedAction && completedMultitouchGesture != _TUCCursorGestureNone && !shouldTreatAsTap) {
            [self performMouseEventForGesture:completedMultitouchGesture];
        }
        
        [self stopCurrentGesture];
        
        if (!suppressEndedAction && shouldTreatAsTap) {
            [self performMouseEventForGesture:TUCCursorGestureTap];
        }
        
        return;
    }
    
    
    else if (phase == NSTouchPhaseCancelled) {
        [self stopCurrentGesture];
        return;
    }
    
    if ([self checkForSecondaryClick]) {
        return;
    }

    // If a two-finger gesture ended but one finger remains, clear the old gesture state.
    if (self.identifiedMultitouchGesture != _TUCCursorGestureNone
        && (self.gestureAdditionalTouch == nil || !self.gestureAdditionalTouch.isActive)) {
        [self stopCurrentGesture];
    }
    
    if ([touches count] == 2 && [touches containsObject: cursorTouch]) {
        // check if we need to initiate two finger drag, pinch, ...
        TUCTouch *otherTouch = touches[1];
        if (otherTouch.uuid == cursorTouch.uuid) {
            otherTouch = touches[0];
        }
        // Keep reference in sync every frame to avoid stale pointer causing pinch latch.
        self.gestureAdditionalTouch = otherTouch;

        if (self.identifiedMultitouchGesture == _TUCCursorGestureNone ) {
            if (self.gestureAdditionalTouch.isActive) {
                CGPoint trajectoryA = [cursorTouch trajectorySign];
                CGPoint trajectoryB = [otherTouch trajectorySign];
                
                
                if (   !CGPointEqualToPoint(trajectoryA, CGPointZero)
                    && !CGPointEqualToPoint(trajectoryB, CGPointZero)) {
                    
                    if (!CGPointEqualToPoint(trajectoryA, trajectoryB)) {
                        self.identifiedMultitouchGesture = TUCCursorGesturePinch;
                    }
//                    else {
//                        self.identifiedMultitouchGesture = TUCCursorGestureTwoFingerDrag;
//                    }
                }
                
            } else {
                // secondary click
                [self removeTouch:self.gestureAdditionalTouch now:YES];
                self.gestureAdditionalTouch = nil;
                [self performMouseEventForGesture:TUCCursorGestureTapSecondFinger];
            }
        }
        
        // other finger lifted, gesture ended
        if (!self.gestureAdditionalTouch.isActive) {
            self.gestureAdditionalTouch = nil;
            [self stopCurrentGesture];
        }
        
        
        if(self.identifiedMultitouchGesture != _TUCCursorGestureNone) {
            [self performMouseEventForGesture:self.identifiedMultitouchGesture];
            return;
        }
        
    }
    

    if (self.cursorTouchDidHold) {
        [self performMouseEventForGesture:TUCCursorGestureHoldAndDrag];
    } else {
        // Delay drag/scroll activation until travel is clearly beyond tap jitter.
        if ([self cursorTouchDistanceFromStartMM] <= kTapCancelDistanceMM) {
            return;
        }
        [self performMouseEventForGesture:TUCCursorGestureDrag];
    }
}


/**
 A hold is a single finger that stays within the tap slop of its touch-down point for `holdDuration`.
 Measuring against the touch-down point (instead of frame-to-frame stillness) keeps holds working on
 large or noisy panels where a resting finger jitters slightly every report.
 Once recognized, the left button goes down right away so the next movement drags (e.g. a window title bar).
 Returns YES if the hold was recognized in this frame.
 */
- (BOOL)updateCursorTouchHoldStateWithActiveTouchCount:(NSUInteger)activeTouchCount {
    if (self.cursorTouchDidHold
        || !self.cursorTouchQualifiedForTap
        || self.cursorTouchBeganDate == nil
        || activeTouchCount > 1
        || self.identifiedMultitouchGesture != _TUCCursorGestureNone
        || self.cursorTouch.phase == NSTouchPhaseEnded
        || self.cursorTouch.phase == NSTouchPhaseCancelled) {
        return NO;
    }
    
    NSTimeInterval touchDuration = [[NSDate date] timeIntervalSinceDate:self.cursorTouchBeganDate];
    if (touchDuration < self.holdDuration || [self cursorTouchDistanceFromStartMM] > kTapCancelDistanceMM) {
        return NO;
    }
    
    self.cursorTouchDidHold = YES;
    [self performMouseEventForGesture:TUCCursorGestureHoldAndDrag];
    return YES;
}


- (BOOL)checkForSecondaryClick {
//    if (self.identifiedMultitouchGesture != _TUCCursorGestureNone) {
//        return NO;
//    }

    if (self.cursorTouch == nil || self.cursorTouchBeganDate == nil) {
        return NO;
    }
    
    NSSet<TUCTouch *> *touchesInProximity = [self touchesInProximityTo:self.cursorTouch.location maxDistance:60];
    if (touchesInProximity.count >= 2 && self.identifiedMultitouchGesture == _TUCCursorGestureNone) {

        // TUCCursorGestureTwoFingerTap
        NSPredicate *p1 = [NSPredicate predicateWithFormat:@"phase == %d", NSTouchPhaseEnded];
        NSPredicate *p2 = [NSPredicate predicateWithFormat:@"phase == %d", NSTouchPhaseCancelled];

        NSPredicate *p3 = [NSPredicate predicateWithFormat:@"contactID != %d", self.cursorTouch.contactID];

        NSPredicate *p4 = [NSCompoundPredicate orPredicateWithSubpredicates:@[p1, p2]];
        NSPredicate *p5 = [NSCompoundPredicate andPredicateWithSubpredicates:@[p3, p4]];

        NSPredicate *p6 = [NSPredicate predicateWithBlock:^BOOL(TUCTouch *touch, NSDictionary *bindings) {
            NSDate *lastUpdatedAt = touch.lastUpdatedAt;
            if (lastUpdatedAt == nil) {
                return NO;
            }
            return [lastUpdatedAt compare:self.cursorTouchBeganDate] != NSOrderedAscending;
        }];

        NSSet<TUCTouch *> *endedTouches = [touchesInProximity filteredSetUsingPredicate:[NSCompoundPredicate andPredicateWithSubpredicates:@[p5, p6]]];

        if (endedTouches.count == 1) {
            for (TUCTouch* touchToRemove in endedTouches) {
                [self removeTouch:touchToRemove now:YES];
            }

            [self performMouseEventForGesture:TUCCursorGestureTapSecondFinger];
            return YES;
        }
    }
    return NO;
}


- (void)performMouseEventForGesture:(TUCCursorGesture)gesture {
    TUCTouch *touch = self.cursorTouch;
    
    CGPoint screenLocation = [self convertScreenPointRelativeToAbsolute:touch.location];
    CGPoint location2ndFinger = [self convertScreenPointRelativeToAbsolute:self.gestureAdditionalTouch.location];
    
    TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
    
    TUCCursorAction action = [self actionForGesture:gesture];
    TUCCursorAction previousAction = self.lastPerformedAction;
    
    if (previousAction != action) {
        if (previousAction == TUCCursorActionMagnify) {
            [utils stopMagnifying];
        }
        if (previousAction == TUCCursorActionDrag) {
            [utils stopDraggingCursor];
        }
        if (previousAction == TUCCursorActionScroll) {
            self.hasLastScrollLocation = NO;
        }
        if (previousAction == TUCCursorActionKeyboardShortcutHold) {
            [utils endHeldShortcut];
        }
    }
    self.lastPerformedAction = action;
    
    CGFloat doubleClickSpan = self.doubleClickTolerance * [[self touchscreen] pixelsPerMM];
    [[TUCCursorUtilities sharedInstance] setDoubleClickTolerance:doubleClickSpan];
    
    switch (action) {
        case TUCCursorActionNone:
            break;
            
        case TUCCursorActionMove:
            [utils moveCursorTo:screenLocation];
            break;
            
        case TUCCursorActionPointAndClick:
            [utils moveCursorTo:screenLocation];
            if (touch.phase == NSTouchPhaseEnded) {
                [utils performClickAt:screenLocation];
            }
            break;
            
        case TUCCursorActionDrag:
            [utils dragCursorTo:screenLocation phase:touch.phase];
            break;
            
        case TUCCursorActionClick:
            [utils performClickAt:screenLocation];
            break;
            
        case TUCCursorActionSecondaryClick:
            [utils performSecondaryClickAt: screenLocation];
            break;
            
        case TUCCursorActionScroll: {
            if (touch.phase == NSTouchPhaseBegan || !self.hasLastScrollLocation) {
                self.lastScrollLocation = screenLocation;
                self.hasLastScrollLocation = YES;
                break;
            }
            
            CGFloat jumpDistanceMM = [self distanceMMFromPoint:touch.location
                                                       toPoint:touch.previousLocation];
            if (jumpDistanceMM > kScrollReanchorDistanceMM) {
                // If the touch stream missed liftoff and the next gesture starts far away,
                // treat it as a fresh scroll session instead of scrolling from stale origin.
                self.lastScrollLocation = screenLocation;
                self.hasLastScrollLocation = YES;
                break;
            }
            
            CGPoint translation = CGPointMake(screenLocation.x - self.lastScrollLocation.x,
                                              screenLocation.y - self.lastScrollLocation.y);
            self.lastScrollLocation = screenLocation;
            CGPoint scaledTranslation = CGPointMake(translation.x * self.scrollSpeedMultiplier,
                                                   translation.y * self.scrollSpeedMultiplier);
            [utils scroll:scaledTranslation phase:touch.phase];
            
            if (touch.phase == NSTouchPhaseEnded || touch.phase == NSTouchPhaseCancelled) {
                self.hasLastScrollLocation = NO;
            }
            
            break; }
            
        case TUCCursorActionMagnify:
            [utils magnifyLocationA:screenLocation
                          locationB:location2ndFinger
            relativeP1:self.cursorTouch.location relP2:self.gestureAdditionalTouch.location];
            
            if (touch.phase == NSTouchPhaseEnded || self.gestureAdditionalTouch.phase == NSTouchPhaseEnded) {
                [utils stopMagnifying];
            }
            break;

        case TUCCursorActionMissionControl:
            [utils performMissionControl];
            break;

        case TUCCursorActionKeyboardShortcutHold:
            [utils beginHoldingShortcutSpec:self.fiveFingerHoldShortcutSpec ?: @""];
            break;

        case TUCCursorActionKeyboardShortcutSequence:
            [utils performShortcutSequenceSpec:self.fourFingerSwipeLeftSequenceSpec ?: @""];
            break;

        case TUCCursorActionFloatingKeyboard:
            [self.delegate performCustomAction:action];
            break;

        case TUCCursorActionHideFloatingKeyboard:
            [self.delegate performCustomAction:action];
            break;
    }
}


- (TUCCursorAction)actionForGesture:(TUCCursorGesture)gesture {
    
    if (self.delegate != nil) {
        return [self.delegate actionForGesture:gesture];
    }
    
    switch(gesture) {
        case TUCCursorGestureTouchDown:         return TUCCursorActionMove;
        case TUCCursorGestureTap:               return TUCCursorActionClick;
        case TUCCursorGestureLongPress:         return TUCCursorActionClick;
        case TUCCursorGestureDrag:              return TUCCursorActionScroll;
        case TUCCursorGestureHoldAndDrag:       return TUCCursorActionDrag;
        case TUCCursorGestureTapSecondFinger:   return TUCCursorActionSecondaryClick;
        case TUCCursorGestureTwoFingerDrag:     return TUCCursorActionDrag;
        case TUCCursorGesturePinch:             return TUCCursorActionMagnify;
        case TUCCursorGestureThreeFingerSwipeUp:return TUCCursorActionMissionControl;
        case TUCCursorGestureFourFingerSwipeLeft:return TUCCursorActionKeyboardShortcutSequence;
        case TUCCursorGestureFiveFingerHold:    return TUCCursorActionKeyboardShortcutHold;
        case TUCCursorGestureFourFingerSwipeUp: return TUCCursorActionFloatingKeyboard;
        case TUCCursorGestureFourFingerSwipeDown:return TUCCursorActionHideFloatingKeyboard;
        case _TUCCursorGestureNone:             return TUCCursorActionNone;
    }
}


#pragma mark - Touch Set

/**
 The `touchSet` can contain touches whose phase is ended or cancelled. activeTouches. filteres those out
 */
- (NSSet<TUCTouch *> *)activeTouches {
    NSPredicate *p1 = [NSPredicate predicateWithFormat:@"phase != %d", NSTouchPhaseEnded];
    NSPredicate *p2 = [NSPredicate predicateWithFormat:@"phase != %d", NSTouchPhaseCancelled];
    
    NSPredicate *predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[p1, p2]];
    
    return [self.touchSet filteredSetUsingPredicate:predicate];
}



- (CGFloat)distanceBetweenPoint:(CGPoint)p1 and:(CGPoint)p2 {
    CGFloat dx = p1.x - p2.x;
    CGFloat dy = p1.y - p2.y;
    
    return sqrt( pow(dx, 2) + pow(dy, 2) );
}


/**
 maxDistance in mm
 */
- (NSSet<TUCTouch *> *)touchesInProximityTo:(CGPoint)point maxDistance:(CGFloat)mmDistance {
    
    CGFloat screenDistance = mmDistance * [[self touchscreen] pixelsPerMM];
    CGPoint distance = CGPointMake(screenDistance /  [self touchscreen].frame.size.width,
                                   screenDistance /  [self touchscreen].frame.size.height);
    
    NSPredicate * predicate = [NSPredicate predicateWithBlock: ^BOOL(TUCTouch *t, NSDictionary *bind) {
        
        CGFloat dx = [t location].x - point.x;
        CGFloat dy = [t location].y - point.y;
        
        return sqrt( pow(dx, 2) + pow(dy, 2) ) < distance.x;
    }];
    
    return [self.touchSet filteredSetUsingPredicate:predicate];
}


/**
 Removes a touch from the touch set. As a previous touch might be important for gesture evaluation, it is removed after half a second
 */
- (void)removeTouch:(TUCTouch *)touch now:(BOOL)instantDeletion{
//    if (touch.uuid == self.touchUsedForCursor.uuid) {
//        [self processTouchesForCursorInput];
//        self.touchUsedForCursor = nil;
//    }
    
    if (instantDeletion) {
        [[self touchSet] removeObject:touch];
        [[self delegate] touchesDidChange];
        return;
    }
    
    __weak id weakSelf = self;
    NSUUID *uuid = touch.uuid;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        for(TUCTouch *touch in [weakSelf touchSet]) {
            if (touch.uuid == uuid && [[weakSelf touchSet] containsObject:touch]) {
                [[weakSelf touchSet] removeObject:touch];
                [[weakSelf delegate] touchesDidChange];
                return;
            }
        }
    });
}


/**
 Checks the touch set if a touch exists
 */
- (TUCTouch *)findTouchWithID:(NSInteger)contactID includingPastTouches:(BOOL)includePastTouches {
    NSSet *set = includePastTouches ? self.touchSet : [self activeTouches];
    
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"contactID == %d", contactID];
    TUCTouch *touch = [[set filteredSetUsingPredicate:predicate] anyObject];
    return touch;
}

/**
 Returns the existing touch object or a new one if this ID does not exist in the set yet.
 */
- (TUCTouch *)obtainTouchWithID:(NSInteger)contactID isNew:(BOOL*)isNew {
    TUCTouch *touch = [self findTouchWithID:contactID includingPastTouches:NO];
    *isNew = NO;
    if(!touch) {
        touch = [[TUCTouch alloc] initWithContactID:contactID];
        [self.touchSet addObject:touch];
        *isNew = YES;
    }
    return touch;
}





#pragma mark - Screen Characteristics

/**
 the relative hardware points are always in the direction the digitizer is built in.
 If the display is rotated, we need to rotate these points
 */
- (CGPoint)convertDigitizerPointToRelativeScreenPoint:(CGPoint)devicePoint {
    CGFloat rotation = [self touchscreen].rotation;
    if (rotation == 0) {
        return devicePoint;
        
    } else if (rotation == 180) {
        return CGPointMake(1 - devicePoint.x, 1 - devicePoint.y);
        
    } else if (rotation == 90) {
        return CGPointMake(1 - devicePoint.y, devicePoint.x);
        
    } else if (rotation == 270) {
        return CGPointMake(devicePoint.y, 1 - devicePoint.x);
    }
    
    return devicePoint;
}



- (CGPoint)convertScreenPointRelativeToAbsolute:(CGPoint)relativePoint {
    return [[self touchscreen] convertPointRelativeToAbsolute:relativePoint];
}



- (TUCScreen *)touchscreen {
    if (self.delegate != nil) {
        return [self.delegate touchscreen];
    }
    
    return [[TUCScreen allScreens] firstObject];
}



- (BOOL)isPointInMenuBar:(CGPoint)point {
    CGFloat menuBarHeight = [[[NSApplication sharedApplication] mainMenu] menuBarHeight];

    CGRect screenFrame = [self touchscreen].frame;
    CGRect menuBarFrame = CGRectMake(screenFrame.origin.x,
                                     screenFrame.origin.y * -1,
                                     screenFrame.size.width,
                                     menuBarHeight);
    
    if (CGRectContainsPoint(menuBarFrame, point)) {
        return YES;
    }
    return NO;
}


- (BOOL)isLocationOutsideFrontmostWindow:(CGPoint)point {
    
    if ([self isPointInMenuBar:point]) {
        return NO;
    }
    
    pid_t frontmostPID = [[[NSWorkspace sharedWorkspace] frontmostApplication] processIdentifier];
    
    CFArrayRef array;
    array = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    
//    NSLog(@"%@", array);
    
    BOOL behindFrontmostWindow = NO;
    
    // propagate through window list the structure of this array is as follows:
    // [control center and menubar] [windows of frontmost app] [windows of other apps]
    // we have to insert a click to bring other windows to front, but not the menubar / control center stuff
    
    BOOL res = NO;
//    CFStringRef name = CFDictionaryGetValue(dic, kCGWindowOwnerPID);
    
    for (CFIndex i=0; i<CFArrayGetCount(array); i++) {
        CFDictionaryRef dic = CFArrayGetValueAtIndex(array, i);
        
        CFNumberRef numPid = CFDictionaryGetValue(dic, kCGWindowOwnerPID);
        pid_t currPID;
        CFNumberGetValue(numPid, kCFNumberIntType,  &currPID);
        BOOL isFrontmostApp = currPID == frontmostPID;
        
        // in fullscreen the app might also own the menu bar backgground window, so we need to test
        CFDictionaryRef bounds = CFDictionaryGetValue(dic, kCGWindowBounds);
        CGRect nextFrame;
        CGRectMakeWithDictionaryRepresentation(bounds, &nextFrame);
        BOOL isInside = CGRectContainsPoint(nextFrame, point);
        
        
        if (isFrontmostApp && !behindFrontmostWindow) {
            behindFrontmostWindow = YES;
        }
        
        
        
        if (isInside && !behindFrontmostWindow) {
            // operate without additional clicks
            res = NO;
            break;
        }
        
        else if (isInside && behindFrontmostWindow && !isFrontmostApp) {
            res = YES;
            break;
        }
        
    }
    
    CFRelease(array);
    return res;
}
        



#pragma mark -

- (instancetype)init {
    if(self = [super init]) {
        self.touchSet = [NSMutableSet new];
        self.postMouseEvents = YES;
        self.penSuppressedContactIDs = [NSMutableSet set];
        
        self.cursorTouchQualifiedForTap = NO;
        self.cursorTouchStationarySinceDate = nil;
        
        self.currentFrameID = 0;
        self.identifiedMultitouchGesture = _TUCCursorGestureNone;
        
        self.doubleClickTolerance = 5;
        self.holdDuration = 0.25;
        self.errorResistance = 0;
        
        self.ignoreOriginTouches = NO;

        self.scrollInertiaEnabled = YES;
        self.scrollInertiaDecelerationPerFrame = 0.95;
        self.scrollInertiaVelocityMultiplier = 1.0;
        self.scrollSpeedMultiplier = 1.4;
        self.threeFingerSwipeEnabled = YES;
        self.fourFingerSwipeUpKeyboardEnabled = YES;
        self.fiveFingerHoldShortcutSpec = @"fn";
        self.fourFingerSwipeLeftSequenceSpec = @"cmd+a, delete";
    }
    return self;
}

- (void)setScrollInertiaEnabled:(BOOL)scrollInertiaEnabled {
    _scrollInertiaEnabled = scrollInertiaEnabled;
    [TUCCursorUtilities sharedInstance].momentumScrollEnabled = scrollInertiaEnabled;
}

- (void)setScrollInertiaDecelerationPerFrame:(CGFloat)scrollInertiaDecelerationPerFrame {
    _scrollInertiaDecelerationPerFrame = scrollInertiaDecelerationPerFrame;
    [TUCCursorUtilities sharedInstance].momentumDecelerationPerFrame = scrollInertiaDecelerationPerFrame;
}

- (void)setScrollInertiaVelocityMultiplier:(CGFloat)scrollInertiaVelocityMultiplier {
    _scrollInertiaVelocityMultiplier = scrollInertiaVelocityMultiplier;
    [TUCCursorUtilities sharedInstance].momentumVelocityMultiplier = scrollInertiaVelocityMultiplier;
}


- (NSString *)debugDescription {
    NSMutableString *str = [[NSString stringWithFormat:@"Touch Set contains %ld touches:{\n", [self.touchSet count]] mutableCopy];
    
    for (TUCTouch *touch in [[self.touchSet allObjects] sortedArrayUsingSelector:@selector(compareWithAnotherTouch:)] ) {
        [str appendString: [NSString stringWithFormat:@"  %@", [touch debugDescription]] ];
        if (touch.contactID == self.cursorTouch.contactID) {
            [str appendString: @" <<<CURSOR>>>\n" ];
        } else {
            [str appendString: @"\n" ];
        }
    }
    
    [str appendString:@"}"];
    return str;
}

#pragma mark - Pen

static const NSTimeInterval kPenPalmRejectionGracePeriod = 0.5;
static const NSTimeInterval kPenUpDebounceInterval = 0.06;

#pragma mark Native pen event filter

/**
 macOS also turns this panel's pen reports into its own tablet-tagged cursor events (hardware source,
 no button held). Interleaved with our button-down drags they end the stroke in apps like Notability,
 which then draw only dots. While a pen stroke is active, drop those hardware tablet events.
 */
static CGEventRef TUCNativePenEventFilterCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    TUCTouchInputManager *manager = (__bridge TUCTouchInputManager *)userInfo;
    
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (manager.nativePenEventTap != NULL) {
            CGEventTapEnable(manager.nativePenEventTap, true);
        }
        return event;
    }
    
    // Only hardware events (our own carry this process's PID), and only tablet-tagged ones.
    if (CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID) != 0) {
        return event;
    }
    int64_t subtype = CGEventGetIntegerValueField(event, kCGMouseEventSubtype);
    BOOL isTabletEvent = type == kCGEventTabletPointer
        || type == kCGEventTabletProximity
        || subtype == kCGEventMouseSubtypeTabletPoint
        || subtype == kCGEventMouseSubtypeTabletProximity;
    if (!isTabletEvent || ![manager isPenActive]) {
        return event;
    }
    
    manager.nativePenEventsDropped++;
    return NULL;
}

- (void)installNativePenEventFilter {
    if (self.nativePenEventTap != NULL) {
        return;
    }
    CGEventMask mask = CGEventMaskBit(kCGEventMouseMoved)
        | CGEventMaskBit(kCGEventLeftMouseDown)
        | CGEventMaskBit(kCGEventLeftMouseUp)
        | CGEventMaskBit(kCGEventLeftMouseDragged)
        | CGEventMaskBit(kCGEventTabletPointer)
        | CGEventMaskBit(kCGEventTabletProximity);
    CFMachPortRef tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                         mask, TUCNativePenEventFilterCallback, (__bridge void *)self);
    if (tap == NULL) {
        NSLog(@"[Pen] could not install native pen event filter (Accessibility permission?)");
        return;
    }
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);
    self.nativePenEventTap = tap;
    self.nativePenEventTapSource = source;
    NSLog(@"[Pen] native pen event filter installed");
}

- (void)removeNativePenEventFilter {
    if (self.nativePenEventTap == NULL) {
        return;
    }
    CGEventTapEnable(self.nativePenEventTap, false);
    if (self.nativePenEventTapSource != NULL) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), self.nativePenEventTapSource, kCFRunLoopCommonModes);
        CFRelease(self.nativePenEventTapSource);
        self.nativePenEventTapSource = NULL;
    }
    CFMachPortInvalidate(self.nativePenEventTap);
    CFRelease(self.nativePenEventTap);
    self.nativePenEventTap = NULL;
}


- (void)finishPenStroke {
    self.penUpDebounceTimer = nil;
    if (!self.penIsDown) {
        return;
    }
    NSLog(@"[Pen] up at (%.0f, %.0f) after %ld drag events, %ld native events filtered so far", self.penLastLocation.x, self.penLastLocation.y, (long)self.penStrokeDragCount, (long)self.nativePenEventsDropped);
    [[TUCCursorUtilities sharedInstance] penUpAt:self.penLastLocation];
    self.penIsDown = NO;
    self.penLastActiveDate = [NSDate date];
}

- (BOOL)isPenActive {
    if (self.penIsDown) {
        return YES;
    }
    return self.penLastActiveDate != nil
        && [[NSDate date] timeIntervalSinceDate:self.penLastActiveDate] < kPenPalmRejectionGracePeriod;
}

/**
 Ends any finger gesture in progress and ignores those fingers until they lift,
 so a resting palm neither scrolls nor clicks while drawing.
 */
- (void)suppressFingerTouchesForPen {
    for (TUCTouch *touch in [self.touchSet allObjects]) {
        if (touch.isActive) {
            [self.penSuppressedContactIDs addObject:@(touch.contactID)];
        }
    }
    [self stopCurrentGesture];
    self.cursorTouch = nil;
    [[TUCCursorUtilities sharedInstance] cancelMomentumScroll];
}

- (void)updatePenAtDigitizerPoint:(CGPoint)digitizerPoint tip:(BOOL)tip inRange:(BOOL)inRange pressure:(CGFloat)pressure eraser:(BOOL)eraser {
    if (!self.postMouseEvents) {
        return;
    }
    
    if (inRange != self.penInRange) {
        NSLog(@"[Pen] in range %d (tip %d)", inRange, tip);
    }
    
    BOOL wasActive = [self isPenActive];
    // Only pen *contact* counts as pen use. In Range alone is not reliable: pens resting in the
    // board's tray can report In Range indefinitely, which would lock out all finger input.
    if (tip && !wasActive) {
        [self suppressFingerTouchesForPen];
    }
    
    CGPoint relative = [self convertDigitizerPointToRelativeScreenPoint:digitizerPoint];
    CGPoint location = [self convertScreenPointRelativeToAbsolute:relative];
    TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
    
    if (tip) {
        // The tip came back before the lift was confirmed: keep drawing the same stroke.
        [self.penUpDebounceTimer invalidate];
        self.penUpDebounceTimer = nil;
    }
    
    if (tip && !self.penIsDown) {
        NSLog(@"[Pen] down at (%.0f, %.0f)", location.x, location.y);
        self.penStrokeDragCount = 0;
        [utils penDownAt:location pressure:pressure];
        self.penIsDown = YES;
    } else if (tip) {
        [utils penDragTo:location pressure:pressure];
        self.penStrokeDragCount++;
    } else if (self.penIsDown) {
        // Some panels drop the tip switch for a report or two mid-stroke. Only end the stroke
        // if the tip stays up briefly, otherwise one line breaks into many short pieces.
        if (self.penUpDebounceTimer == nil) {
            self.penUpDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:kPenUpDebounceInterval
                                                                       target:self
                                                                     selector:@selector(finishPenStroke)
                                                                     userInfo:nil
                                                                      repeats:NO];
        }
    }
    
    self.penLastLocation = location;
    
    self.penInRange = inRange;
    if (tip) {
        self.penLastActiveDate = [NSDate date];
    }
}


- (void)triggerSystemAccessibilityAccessAlert {
    CGPoint loc = [[TUCCursorUtilities sharedInstance] currentCursorLocation];
    [[TUCCursorUtilities sharedInstance] moveCursorTo:loc];
}

- (void)performShortcutChordSpec:(NSString *)shortcutSpec {
    [[TUCCursorUtilities sharedInstance] performShortcutChordSpec:shortcutSpec];
}



#pragma mark - Bridge calls of C Header to Objective-C

void TouchInputManagerUpdateTouchPosition(void *self, CFIndex contactID, CGFloat x, CGFloat y, Boolean onSurface, Boolean isValid) {
    CGPoint point = CGPointMake(x, y);
    [(__bridge id)self updateTouch:(NSInteger)contactID withLocation:point onSurface:onSurface tooLargeForFinger:isValid];
}

void TouchInputManagerUpdateTouchSize(void *self, CFIndex contactID, CGFloat width, CGFloat height, CGFloat azimuth) {
    CGSize size = CGSizeMake(width, height);
    [(__bridge id)self updateTouch:(NSInteger)contactID withSize:size azimuth:azimuth];
}

void TouchInputManagerUpdatePen(void *self, CGFloat x, CGFloat y, Boolean tip, Boolean inRange, CGFloat pressure, Boolean eraser) {
    [(__bridge id)self updatePenAtDigitizerPoint:CGPointMake(x, y) tip:tip inRange:inRange pressure:pressure eraser:eraser];
}

void TouchInputManagerDidProcessReport(void *self) {
    [(__bridge id)self didProcessReport];
}

void TouchInputManagerDidConnectTouchscreen(void *self) {
    [(__bridge id)self didConnectTouchscreen];
}

void TouchInputManagerDidDisconnectTouchscreen(void *self) {
    [(__bridge id)self didDisconnectTouchscreen];
}


@end
