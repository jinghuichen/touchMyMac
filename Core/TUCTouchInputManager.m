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
@property BOOL cursorTouchStoppedMomentum; // the touch landed during inertia, so lifting it is not a click

// A touch session lasts from the first finger landing until all fingers lifted.
@property NSInteger sessionMaxTouchCount;
@property BOOL twoFingerTapPossible; // two fingers, both still close to where they landed
@property BOOL pendingTwoFingerTap; // the cursor finger lifted first; waiting for the second one
@property CGPoint pendingTwoFingerTapLocation;

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
static const CGFloat kFourFingerSwipeTriggerTravelMM = 20.0f;
static const CGFloat kFourFingerSwipeMaxVerticalTravelMM = 18.0f;
static const CGFloat kFourFingerSwipeMaxHorizontalTravelMM = 18.0f;
static const NSTimeInterval kFiveFingerHoldActivationDuration = 0.25;
static const CGFloat kFiveFingerHoldMaxTravelMM = 12.0f;
static const CGFloat kClaimedTouchJumpDistanceMM = 8.0f;
static const NSTimeInterval kTwoFingerTapMaxDuration = 0.5;

#pragma mark   Start & Stop

- (void)start {
    
    __weak id weakSelf = self;
    
    // needs to run on main anyway
//    [NSThread detachNewThreadWithBlock:^{
//        [NSThread setThreadPriority:1];
        OpenHIDManager((__bridge void *)(weakSelf));
//    }];

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

        // Ended touches linger in the set for a moment; only expire each touch once.
        if (touch.isActive && touch.lastUpdated + self.errorResistance < self.currentFrameID) {
            // Some touchscreens don't reliably report liftoff (tip switch off) for the final contact.
            // If a touch disappears from the report stream, treat it as a liftoff so tap/scroll end
            // can still be recognized.
            [touch setIsOnSurface:NO];
            [touch setPhase:NSTouchPhaseEnded];
            [self removeTouch:touch now:NO];
        }
    }
    
    ++self.currentFrameID;
    self.debugProcessFrameID = self.currentFrameID;
    self.debugActiveTouchCount = (NSInteger)[[self activeTouches] count];

    // Process before tearing the gesture down, so a liftoff still sees the gesture it ends
    // (e.g. the final scroll frame that hands over to inertia).
    [self processTouchesForCursorInput];

    if ([[self activeTouches] count] == 0) {
        [self stopCurrentGesture];
    }
    [self finishPendingTwoFingerTapIfNeeded];
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
        [self finishPendingTwoFingerTapIfNeeded];
        [self.delegate touchesDidChange];
    }
}

- (CGFloat)distanceMMFromPoint:(CGPoint)p1 toPoint:(CGPoint)p2 {
    // Points are relative to the screen, so each axis scales with its own physical extent.
    CGSize physicalSize = [self touchscreen].physicalSize;
    CGFloat dxMM = (p1.x - p2.x) * physicalSize.width;
    CGFloat dyMM = (p1.y - p2.y) * physicalSize.height;
    return sqrt(dxMM * dxMM + dyMM * dyMM);
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
    [[TUCCursorUtilities sharedInstance] endScrollGesture];
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
    
    CGPoint point = [self convertDigitizerPointToRelativeScreenPoint:digitizerPoint];
    
    BOOL isNewTouch = NO;
    TUCTouch *touch = [self obtainTouchWithID:contactID isNew:&isNewTouch];

    if (isNewTouch && isOnSurface && self.postMouseEvents
        && [self.delegate shouldClaimTouch:touch.uuid atScreenLocation:[self convertScreenPointRelativeToAbsolute:point]]) {
        touch.isClaimed = YES;
    }

    if (touch.isClaimed) {
        [self updateClaimedTouch:touch withLocation:point onSurface:isOnSurface isNew:isNewTouch
                       contactID:contactID digitizerPoint:digitizerPoint tooLargeForFinger:confidenceFlag];
        return;
    }

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
        self.sessionMaxTouchCount = 1;
        self.twoFingerTapPossible = YES;
        self.pendingTwoFingerTap = NO;
        self.cursorTouchStoppedMomentum = [TUCCursorUtilities sharedInstance].isMomentumScrolling;
    }

    [touch setLocation: point];
    if (isNewTouch) {
        touch.initialLocation = point;
    }
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
        BOOL isStationary = [self distanceMMFromPoint:touch.location toPoint:touch.previousLocation] < kStationaryThresholdMM;
        
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


/**
 Claimed touches only need to be kept alive and ended; the delegate does everything else.
 */
- (void)updateClaimedTouch:(TUCTouch *)touch
              withLocation:(CGPoint)point
                 onSurface:(BOOL)isOnSurface
                     isNew:(BOOL)isNewTouch
                 contactID:(NSInteger)contactID
            digitizerPoint:(CGPoint)digitizerPoint
         tooLargeForFinger:(BOOL)confidenceFlag {

    if (!isNewTouch && isOnSurface && [self distanceMMFromPoint:point toPoint:touch.location] > kClaimedTouchJumpDistanceMM) {
        // Some screens hand a contact ID to the next finger without reporting liftoff in between.
        // During fast typing that next finger lands on another key, so start a fresh touch for it.
        [touch setIsOnSurface:NO];
        [touch setPhase:NSTouchPhaseEnded];
        [self removeTouch:touch now:NO];
        [self updateTouch:contactID withLocation:digitizerPoint onSurface:isOnSurface tooLargeForFinger:confidenceFlag];
        return;
    }

    [touch setLocation:point];
    [touch setIsOnSurface:isOnSurface];
    [touch setLastUpdated:self.currentFrameID];

    if (!isOnSurface) {
        [touch setPhase:NSTouchPhaseEnded];
        [self removeTouch:touch now:NO];
    }
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
    
    TUCTouch *cursorTouch = self.cursorTouch;
    
    
    NSArray<TUCTouch *> *touches = [[self activeTouches] allObjects];
    NSTouchPhase phase = cursorTouch.phase;

    if ((NSInteger)touches.count > self.sessionMaxTouchCount) {
        self.sessionMaxTouchCount = touches.count;
        if (touches.count >= 2 && self.lastPerformedAction != TUCCursorActionDrag) {
            // A second finger means this is not a one-finger hold-and-drag.
            self.cursorTouchDidHold = NO;
        }
    }
    if (self.twoFingerTapPossible) {
        self.twoFingerTapPossible = touches.count <= 2 && ![self anyTouchMovedFromInitialLocation:touches];
    }

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

        return;
    }

    if (phase == NSTouchPhaseBegan) {
        [self performMouseEventForGesture:TUCCursorGestureTouchDown];
        return;
    }
    
    
    else if (phase == NSTouchPhaseStationary) {
        NSTimeInterval holdDuration = 0;
        if (self.cursorTouchStationarySinceDate != nil) {
            holdDuration = [[NSDate date] timeIntervalSinceDate:self.cursorTouchStationarySinceDate];
        }
        if (self.cursorTouchQualifiedForTap && holdDuration > self.holdDuration && self.sessionMaxTouchCount < 2) {
            // the user left the finger on the screen for the min duration required to produce a hold
            self.cursorTouchDidHold = YES;
        }

        if (self.lastPerformedAction == TUCCursorActionScroll) {
            // Report the pause to the scroll, so lifting a finger that stopped doesn't fling.
            [self performMouseEventForGesture:TUCCursorGestureDrag];
        }

        return;
    }
    
    
    else if (phase == NSTouchPhaseEnded) {
        CGFloat movementMM = [self cursorTouchDistanceFromStartMM];
        NSTimeInterval touchDuration = self.cursorTouchBeganDate == nil ? 0 : [[NSDate date] timeIntervalSinceDate:self.cursorTouchBeganDate];
        BOOL shortTouchWithSmallTravel = touchDuration <= kTapFallbackDuration && movementMM <= kTapFallbackDistanceMM;
        // Only a single finger on its own can be a tap.
        BOOL noOtherActiveTouches = touches.count == 0 && self.sessionMaxTouchCount < 2;
        BOOL shouldTreatAsTap = noOtherActiveTouches && (self.cursorTouchQualifiedForTap || shortTouchWithSmallTravel);
        BOOL suppressEndedAction = self.suppressEndedPrimaryTouchAction;

        if (!suppressEndedAction && self.sessionMaxTouchCount == 2 && self.twoFingerTapPossible) {
            CGPoint location = [self convertScreenPointRelativeToAbsolute:cursorTouch.location];
            [self stopCurrentGesture];
            if (touches.count == 0) {
                [self performTwoFingerTapAt:location];
            } else {
                // The cursor finger lifted first; the tap completes when the other finger lifts.
                self.pendingTwoFingerTap = YES;
                self.pendingTwoFingerTapLocation = location;
            }
            self.cursorTouch = nil;
            return;
        }
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
        
        if (!suppressEndedAction && shouldTreatAsTap && !self.cursorTouchStoppedMomentum) {
            [self performMouseEventForGesture:TUCCursorGestureTap];
        }

        // The ended touch lingers in the set for a moment. Release it so reports from other
        // fingers don't run this liftoff logic again (which used to fire a late tap here).
        self.cursorTouch = nil;
        return;
    }
    
    
    else if (phase == NSTouchPhaseCancelled) {
        [self stopCurrentGesture];
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

        // While both fingers rest where they landed this may still be a two-finger tap,
        // so finger jitter must not start a pinch.
        if (self.identifiedMultitouchGesture == _TUCCursorGestureNone && !self.twoFingerTapPossible) {
            CGPoint trajectoryA = [cursorTouch trajectorySign];
            CGPoint trajectoryB = [otherTouch trajectorySign];

            if (   !CGPointEqualToPoint(trajectoryA, CGPointZero)
                && !CGPointEqualToPoint(trajectoryB, CGPointZero)
                && !CGPointEqualToPoint(trajectoryA, trajectoryB)) {
                self.identifiedMultitouchGesture = TUCCursorGesturePinch;
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

    if (self.sessionMaxTouchCount >= 2 && self.twoFingerTapPossible) {
        return;
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


#pragma mark - Two-Finger Tap

- (BOOL)anyTouchMovedFromInitialLocation:(NSArray<TUCTouch *> *)touches {
    for (TUCTouch *touch in touches) {
        if ([self distanceMMFromPoint:touch.location toPoint:touch.initialLocation] > kTapCancelDistanceMM) {
            return YES;
        }
    }
    return NO;
}

/**
 Two fingers that land and lift without moving make a secondary click, like a tap on a Mac trackpad.
 The tap must finish within `kTwoFingerTapMaxDuration` of the first finger landing.
 */
- (void)performTwoFingerTapAt:(CGPoint)screenLocation {
    NSTimeInterval duration = self.cursorTouchBeganDate == nil ? 0 : [[NSDate date] timeIntervalSinceDate:self.cursorTouchBeganDate];
    if (duration > kTwoFingerTapMaxDuration) {
        return;
    }
    if ([self actionForGesture:TUCCursorGestureTapSecondFinger] == TUCCursorActionSecondaryClick) {
        [[TUCCursorUtilities sharedInstance] performSecondaryClickAt:screenLocation];
    }
}

- (void)finishPendingTwoFingerTapIfNeeded {
    if (!self.pendingTwoFingerTap) {
        return;
    }

    NSArray<TUCTouch *> *touches = [[self activeTouches] allObjects];
    if ([self anyTouchMovedFromInitialLocation:touches]) {
        self.pendingTwoFingerTap = NO;
        return;
    }
    if (touches.count > 0) {
        return;
    }

    self.pendingTwoFingerTap = NO;
    [self performTwoFingerTapAt:self.pendingTwoFingerTapLocation];
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
            [utils endScrollGesture];
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
 The `touchSet` can contain touches whose phase is ended or cancelled, and touches claimed by the delegate.
 activeTouches filters those out, leaving the touches that take part in cursor and gesture handling.
 */
- (NSSet<TUCTouch *> *)activeTouches {
    NSMutableSet<TUCTouch *> *active = [NSMutableSet setWithCapacity:self.touchSet.count];
    for (TUCTouch *touch in self.touchSet) {
        if (touch.isActive && !touch.isClaimed) {
            [active addObject:touch];
        }
    }
    return active;
}




/**
 Removes a touch from the touch set. As a previous touch might be important for gesture evaluation, it is removed after half a second
 */
- (void)removeTouch:(TUCTouch *)touch now:(BOOL)instantDeletion{
    if (touch.isClaimed) {
        [self.delegate claimedTouchDidEnd:touch.uuid];
    }

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
    // Runs for every contact in every report, so avoid building predicates here.
    for (TUCTouch *touch in self.touchSet) {
        if (touch.contactID == contactID && (includePastTouches || touch.isActive)) {
            return touch;
        }
    }
    return nil;
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
        
        self.cursorTouchQualifiedForTap = NO;
        self.cursorTouchStationarySinceDate = nil;
        
        self.currentFrameID = 0;
        self.identifiedMultitouchGesture = _TUCCursorGestureNone;
        
        self.doubleClickTolerance = 5;
        self.holdDuration = 0.08;
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

- (void)triggerSystemAccessibilityAccessAlert {
    CGPoint loc = [[TUCCursorUtilities sharedInstance] currentCursorLocation];
    [[TUCCursorUtilities sharedInstance] moveCursorTo:loc];
}

- (void)performKeyCode:(CGKeyCode)keyCode modifierFlags:(CGEventFlags)flags {
    [[TUCCursorUtilities sharedInstance] performKeyCode:keyCode modifierFlags:flags];
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
