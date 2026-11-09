//
//  TUCTouchInputManager.m
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#import "TUCTouchInputManager.h"

#import "HIDInterpreter.h"
#import "TUCCursorUtilities.h"
#import <ApplicationServices/ApplicationServices.h>

/// What Accessibility reports under the finger that moves the cursor.
typedef NS_ENUM(NSInteger, TUCControlUnderTouch) {
    TUCControlUnderTouchPending,
    TUCControlUnderTouchDraggable, // a slider, scroll bar, splitter or title bar: dragging moves it
    TUCControlUnderTouchOther,
};

@interface TUCTouchInputManager ()

@property NSInteger currentFrameID;

@property (weak, nullable) TUCTouch *cursorTouch;
@property (weak, nullable) TUCTouch *gestureAdditionalTouch;

@property BOOL cursorTouchQualifiedForTap; // if the cursor entered moving state once it can no longer be interpreted as tap
@property BOOL cursorTouchDidHold; //
@property (strong) NSDate *cursorTouchBeganDate;
@property CGPoint cursorTouchStartLocation;
@property TUCControlUnderTouch controlUnderCursorTouch;
@property BOOL deviceReportsLiftoff; // the screen sends liftoffs, so a quiet finger is still down
@property BOOL longPressFeedbackShown;
@property NSInteger controlLookupSession; // bumped per touch, so a late answer can't apply to the next touch
@property CGPoint controlPressLocation; // where a control drag presses (global), e.g. snapped onto a divider
@property BOOL fingerOnDesktopBar; // on Mission Control's row of desktops, whose close buttons need Option to show
@property BOOL hasWindowButtonTapLocation; // the finger landed beside a window's close, minimize or zoom button
@property CGPoint windowButtonTapLocation; // that button's centre (global), where a tap clicks instead
@property BOOL holdingOptionForDesktopBar;
@property (strong) NSDate *optionDownDate;
@property TUCCursorAction lastPerformedAction;
@property BOOL suppressEndedPrimaryTouchAction;
@property BOOL cursorTouchStoppedMomentum; // the touch landed on visibly moving inertia, so lifting it is not a click

// A touch session lasts from the first finger landing until all fingers lifted.
@property NSInteger sessionMaxTouchCount;
@property BOOL twoFingerTapPossible; // two fingers, both still close to where they landed
@property BOOL pendingTwoFingerTap; // the cursor finger lifted first; waiting for the second one
@property CGPoint pendingTwoFingerTapLocation;

@property CGFloat pinchDistance;
@property BOOL hasLastScrollLocation;
@property CGPoint lastScrollLocation;

@property TUCCursorGesture identifiedMultitouchGesture;

// Gestures with three or more fingers are recognized per session (first finger down until all fingers
// lifted, claimed touches included), so fingers dropping out or lifting one by one can't change them.
@property NSInteger gestureFingerCount; // most fingers that stayed down for `kStableTouchCountReports` reports
@property NSInteger lastReportTouchCount;
@property NSInteger lastReportTouchCountRepeats;
@property CGPoint multiFingerTravel; // centroid travel in relative screen units
@property CGPoint multiFingerLastCentroid;
@property NSInteger multiFingerLastCentroidCount;
@property BOOL multiFingerGestureTriggered;
@property BOOL claimedTouchesBecameGesture;
// A three-finger swipe opened Mission Control and no tap has closed it yet. Four- and five-finger
// gestures are ignored meanwhile, since showing the keyboard or firing shortcuts over it gets it stuck.
@property BOOL missionControlMayBeOpen;
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
// A three-finger swipe between spaces that the spaces follow, like on a trackpad.
@property BOOL spaceSwipeActive;
@property CGFloat spaceSwipeProgress;
@property CGFloat spaceSwipeVelocity; // progress per second, smoothed
@property (strong) NSDate *spaceSwipeLastMoveDate;

@property (strong) NSTimer *touchInactivityTimer;

@end


@implementation TUCTouchInputManager

@synthesize scrollInertiaEnabled = _scrollInertiaEnabled;
@synthesize scrollInertiaDecelerationPerFrame = _scrollInertiaDecelerationPerFrame;
@synthesize scrollInertiaVelocityMultiplier = _scrollInertiaVelocityMultiplier;

static const CGFloat kStationaryThresholdMM = 0.1f;
/**
 One finger is classified the way Android's GestureDetector does it: it stays a possible tap until it moves
 further than the tap slop from where it landed (then it scrolls) or stays inside it for the hold duration
 (then it presses the mouse). Lifting a possible tap clicks, however long it took.
 Fingers flattening or rolling as they land move the contact point up to 3 mm on some screens, so the slop
 is wider than Android's 8 dp (about 1.3 mm on a phone). Deliberate swipes pass it within about 20 ms.
 */
static const CGFloat kTapSlopMM = 6.0f;
// Two fingers pinch once their distance changes this much (Android uses twice the touch slop). Both
// fingers drift as they land, so their distance can wander up to about twice one finger's drift.
static const CGFloat kPinchSpanSlopMM = 8.0f;
static const NSTimeInterval kControlLookupWait = 0.15; // how long a moving finger waits for Accessibility's answer
static const CGFloat kSplitterReachMM = 4; // a finger this close to a divider grabs it
static const CGFloat kTitleBarBandPoints = 40; // the top of a window that drags it, for apps that don't report a title bar
static const CGFloat kWindowEdgeInsidePoints = 4; // a finger this far inside a window's edge resizes it (macOS itself: 3)
static const CGFloat kWindowCornerInsidePoints = 14; // near both edges this far inside, the corner resizes it
static const NSTimeInterval kDesktopCloseButtonsAppearTime = 0.15; // Option shows Mission Control's close buttons, fading in
static const CGFloat kWindowButtonReachMM = 4; // a tap this close to a window's close, minimize or zoom button clicks it

static BOOL TUCDraggableControlAtLocation(CGPoint location, CGFloat splitterReach, CGFloat titleBarHeight, CGPoint *pressLocation);
static BOOL TUCIsOnMissionControlDesktopBar(CGPoint location);
static BOOL TUCFindNearbyWindowButton(CGPoint location, CGFloat reach, CGPoint *buttonLocation);
static void TUCPostOptionKey(bool down);
// Inertia slower than this (points per second, under ~1.3 points per 60Hz frame) looks stopped,
// so a tap then is a click. Faster, the tap only stops the scroll, like on iPad.
static const CGFloat kTapStopsMomentumSpeed = 80.0f;
static const CGFloat kScrollReanchorDistanceMM = 25.0f;
// Some screens never report a liftoff, they just stop reporting; then a touch ends after this much silence.
static const NSTimeInterval kTouchInactivityTimeout = 0.12;
// Screens that do report liftoffs may also go quiet while a finger rests still. Ending the touch then
// released long presses mid-drag, so once a liftoff has been seen only a much longer silence ends a touch.
static const NSTimeInterval kTouchInactivityTimeoutWithLiftoffs = 1.0;
static const CGFloat kThreeFingerSwipeTriggerTravelMM = 18.0f;
static const CGFloat kThreeFingerSwipeMaxHorizontalTravelMM = 18.0f;
static const CGFloat kThreeFingerSwipeMaxVerticalTravelMM = 18.0f;
static const NSTimeInterval kSpaceSwipeStillAfter = 0.15; // fingers that stopped this long before lifting let go at rest
static const CGFloat kSpaceSwipeCommitProgress = 0.25; // dragged this far (screen widths), lifting switches
static const CGFloat kSpaceSwipeFlingVelocity = 0.3; // a flick this fast (screen widths per second) switches too
static const CGFloat kSpaceSwipeFlingBackVelocity = 0.5; // a flick back this fast springs back however far it went
static const CGFloat kSpaceSwipeFlingMinProgress = 0.04; // but only after the spaces visibly moved
static const CGFloat kFourFingerSwipeTriggerTravelMM = 20.0f;
static const CGFloat kFourFingerSwipeMaxCrossTravelMM = 18.0f;
static const NSInteger kStableTouchCountReports = 3; // a finger count must last this long to count for a gesture
static const NSUInteger kClaimedGestureFingerCount = 4; // fingers on the keyboard that make a gesture, not key presses
static const NSTimeInterval kFiveFingerHoldActivationDuration = 0.25;
static const CGFloat kFiveFingerHoldMaxTravelMM = 12.0f;
static const CGFloat kClaimedTouchJumpDistanceMM = 8.0f;
static const CGFloat kClaimedTouchRestingStepMM = 2.0f; // a finger moving less than this per report was resting
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


- (NSString *)connectedTouchscreenName {
    CFStringRef name = HIDCopyActiveTouchscreenName();
    return name == NULL ? nil : (NSString *)CFBridgingRelease(name);
}

- (BOOL)hidManagerOpenFailed {
    return HIDManagerOpenFailed();
}

- (void)didConnectTouchscreen {
    self.deviceReportsLiftoff = NO;
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

    NSArray<TUCTouch *> *allTouches = [[self allActiveTouches] allObjects];
    [self updateGestureFingerCountWithTouches:allTouches];

    // Process before tearing the gesture down, so a liftoff still sees the gesture it ends
    // (e.g. the final scroll frame that hands over to inertia).
    if (![self processMultiFingerGestureWithTouches:allTouches]) {
        [self processTouchesForCursorInput];
    }

    if ([[self activeTouches] count] == 0) {
        [self stopCurrentGesture];
    }
    if (allTouches.count == 0) {
        [self resetMultiFingerSession];
    }
    [self finishPendingTwoFingerTapIfNeeded];
    [self.delegate inputDiagnosticsDidChange];
    
}

- (void)handleTouchInactivityTimer:(NSTimer *)timer {
    if (self.touchSet.count == 0) {
        return;
    }

    // A finger resting still may send no reports, so the hold is also checked here, on time.
    if (self.postMouseEvents && self.cursorTouch.isActive && [self cursorTouchReachedHold]) {
        [self beginLongPress];
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
        if (idle < (self.deviceReportsLiftoff ? kTouchInactivityTimeoutWithLiftoffs : kTouchInactivityTimeout)) {
            continue;
        }

        // If the device stops sending reports on liftoff (common for some touchscreens),
        // synthesize an Ended phase so taps and scroll/drags can terminate.
        [touch setIsOnSurface:NO];
        [touch setPhase:NSTouchPhaseEnded];

        if (self.cursorTouch != nil && touch.uuid == self.cursorTouch.uuid && self.gestureFingerCount < 3) {
            // Drive the existing gesture state machine to decide between tap/drag/hold&drag.
            [self processTouchesForCursorInput];
        }

        [self removeTouch:touch now:NO];
        didChange = YES;
    }

    if (didChange) {
        if ([[self allActiveTouches] count] == 0) {
            [self stopCurrentGesture];
            [self resetMultiFingerSession];
        }
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

- (BOOL)isThreeFingerSwipeEnabledInCurrentConfig {
    return self.threeFingerSwipeEnabled;
}

- (BOOL)isFourFingerSwipeLeftEnabledInCurrentConfig {
    return [[self.fourFingerSwipeLeftSequenceSpec stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] > 0;
}

- (BOOL)isFiveFingerHoldEnabledInCurrentConfig {
    return [[self.fiveFingerHoldShortcutSpec stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] > 0;
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
    if (self.longPressFeedbackShown) {
        self.longPressFeedbackShown = NO;
        if ([self.delegate respondsToSelector:@selector(touchDidEndLongPress)]) {
            [self.delegate touchDidEndLongPress];
        }
    }
    [[TUCCursorUtilities sharedInstance] stopDraggingCursor];
    [[TUCCursorUtilities sharedInstance] stopMagnifying];
    [[TUCCursorUtilities sharedInstance] endScrollGesture];
    self.hasLastScrollLocation = NO;
    self.lastPerformedAction = TUCCursorActionNone;
    self.suppressEndedPrimaryTouchAction = NO;

    self.identifiedMultitouchGesture = _TUCCursorGestureNone;
    self.gestureAdditionalTouch = nil;
}



/**
 Most important event handling callback: it posts the events to the system where the touches need to go
 */
- (void)updateTouch:(NSInteger)contactID withLocation:(CGPoint)digitizerPoint onSurface:(BOOL)isOnSurface tooLargeForFinger:(BOOL)confidenceFlag {
    
    TUCTouch *liftedTouch = nil;
    if (!isOnSurface) {
        liftedTouch = [self findTouchWithID:contactID includingPastTouches:NO];
        if (liftedTouch == nil) {
            return; // a liftoff for a contact that already ended
        }
        self.deviceReportsLiftoff = YES;
    } else if (self.ignoreOriginTouches && CGPointEqualToPoint(digitizerPoint, CGPointZero)) {
        // Some screens send stray contacts at (0,0).
        return;
    }

    // Many screens report a liftoff without coordinates, at (0,0). Dropping it as a stray contact left the
    // touch on until reports had stopped for a while, so a quick second tap continued the first one and a
    // fast double click never happened. The liftoff ends the touch where it last was.
    CGPoint point = (liftedTouch != nil && CGPointEqualToPoint(digitizerPoint, CGPointZero))
        ? liftedTouch.location
        : [self convertDigitizerPointToRelativeScreenPoint:digitizerPoint];
    
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
        self.cursorTouchBeganDate = [NSDate date];
        self.cursorTouchStartLocation = point;
        self.gestureAdditionalTouch = nil;
        self.sessionMaxTouchCount = 1;
        self.twoFingerTapPossible = YES;
        self.pendingTwoFingerTap = NO;
        // Read before this touch-down stops the inertia.
        self.cursorTouchStoppedMomentum = [TUCCursorUtilities sharedInstance].momentumScrollSpeed >= kTapStopsMomentumSpeed;
        self.controlUnderCursorTouch = TUCControlUnderTouchOther;
        [self releaseOptionForDesktopBar];
        self.fingerOnDesktopBar = NO;
        self.hasWindowButtonTapLocation = NO;
        if (isOnSurface) {
            [self lookUpControlAtLocation:[self convertScreenPointRelativeToAbsolute:point]];
        }
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
            if ([self cursorTouchDistanceFromStartMM] > kTapSlopMM) {
                self.cursorTouchQualifiedForTap = NO;
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

    BOOL wasResting = [self distanceMMFromPoint:touch.location toPoint:touch.previousLocation] < kClaimedTouchRestingStepMM;
    if (!isNewTouch && isOnSurface && wasResting
        && [self distanceMMFromPoint:point toPoint:touch.location] > kClaimedTouchJumpDistanceMM) {
        // Some screens hand a contact ID to the next finger without reporting liftoff in between.
        // During fast typing that next finger lands on another key, so start a fresh touch for it.
        // A finger that was already moving (dragging the keyboard) is just moving fast.
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
    } else if (!isNewTouch) {
        [self.delegate claimedTouchDidMove:touch.uuid toScreenLocation:[self convertScreenPointRelativeToAbsolute:point]];
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

    // Three or more fingers are a multi-finger gesture (see `processMultiFingerGestureWithTouches:`).
    // Until that count is stable, do nothing rather than scroll or drag with the first finger.
    if (touches.count >= 3) {
        return;
    }

    if (phase == NSTouchPhaseBegan) {
        [self performMouseEventForGesture:TUCCursorGestureTouchDown];
        return;
    }

    if ((phase == NSTouchPhaseStationary || phase == NSTouchPhaseMoved) && [self cursorTouchReachedHold]) {
        [self beginLongPress];
        return;
    }
    
    if (phase == NSTouchPhaseStationary) {
        if (self.lastPerformedAction == TUCCursorActionScroll) {
            // Report the pause to the scroll, so lifting a finger that stopped doesn't fling.
            [self performMouseEventForGesture:TUCCursorGestureDrag];
        }

        return;
    }
    
    
    else if (phase == NSTouchPhaseEnded) {
        // A tap is a single finger that never left the tap slop and never became a long press.
        BOOL shouldTreatAsTap = self.cursorTouchQualifiedForTap && !self.cursorTouchDidHold
            && touches.count == 0 && self.sessionMaxTouchCount < 2;
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
                // Releases the long press or control drag: that release is the click.
                [self performMouseEventForGesture:TUCCursorGestureHoldAndDrag];
            } else if (!shouldTreatAsTap) {
                [self performMouseEventForGesture:TUCCursorGestureDrag];
            }
        } else if (!suppressEndedAction && completedMultitouchGesture != _TUCCursorGestureNone && !shouldTreatAsTap) {
            [self performMouseEventForGesture:completedMultitouchGesture];
        }
        
        [self stopCurrentGesture];
        
        NSTimeInterval optionShownFor = self.holdingOptionForDesktopBar ? -[self.optionDownDate timeIntervalSinceNow] : INFINITY;
        if (!suppressEndedAction && shouldTreatAsTap && !self.cursorTouchStoppedMomentum && optionShownFor < kDesktopCloseButtonsAppearTime) {
            // The close buttons are still fading in; click once they're there.
            CGPoint location = [self convertScreenPointRelativeToAbsolute:self.cursorTouchStartLocation];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kDesktopCloseButtonsAppearTime - optionShownFor) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [[TUCCursorUtilities sharedInstance] performClickAt:location];
                [self releaseOptionForDesktopBarSoon];
            });
        } else if (!suppressEndedAction && shouldTreatAsTap && !self.cursorTouchStoppedMomentum) {
            [self performMouseEventForGesture:TUCCursorGestureTap];
        }

        if (optionShownFor >= kDesktopCloseButtonsAppearTime || !shouldTreatAsTap || suppressEndedAction || self.cursorTouchStoppedMomentum) {
            [self releaseOptionForDesktopBarSoon];
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

        // other finger lifted, gesture ended
        if (!self.gestureAdditionalTouch.isActive) {
            self.gestureAdditionalTouch = nil;
            [self stopCurrentGesture];
        }

        // Like Android's ScaleGestureDetector: a pinch changes the distance between the fingers, a two-finger
        // scroll moves the point between them. Whichever passes its slop first decides, and the choice stays.
        // While both fingers rest where they landed this may still be a two-finger tap.
        if (self.gestureAdditionalTouch != nil && self.identifiedMultitouchGesture == _TUCCursorGestureNone
            && !self.twoFingerTapPossible && self.lastPerformedAction != TUCCursorActionScroll) {
            CGFloat spanChangeMM = fabs([self distanceMMFromPoint:cursorTouch.location toPoint:otherTouch.location]
                                        - [self distanceMMFromPoint:cursorTouch.initialLocation toPoint:otherTouch.initialLocation]);
            CGPoint focus = CGPointMake((cursorTouch.location.x + otherTouch.location.x) / 2,
                                        (cursorTouch.location.y + otherTouch.location.y) / 2);
            CGPoint initialFocus = CGPointMake((cursorTouch.initialLocation.x + otherTouch.initialLocation.x) / 2,
                                               (cursorTouch.initialLocation.y + otherTouch.initialLocation.y) / 2);
            CGFloat focusMoveMM = [self distanceMMFromPoint:focus toPoint:initialFocus];

            if (spanChangeMM > kPinchSpanSlopMM && spanChangeMM >= focusMoveMM
                && [self actionForGesture:TUCCursorGesturePinch] != TUCCursorActionNone) {
                self.identifiedMultitouchGesture = TUCCursorGesturePinch;
            } else if (focusMoveMM <= kTapSlopMM) {
                return; // neither yet
            }
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
        if (self.longPressFeedbackShown && [self.delegate respondsToSelector:@selector(touchLongPressDidMoveToScreenLocation:)]) {
            [self.delegate touchLongPressDidMoveToScreenLocation:[self convertScreenPointRelativeToAbsolute:cursorTouch.location]];
        }
    } else {
        // Still a possible tap: wait for the finger to leave the tap slop or lift.
        if (self.cursorTouchQualifiedForTap) {
            return;
        }
        if (self.lastPerformedAction != TUCCursorActionScroll && self.sessionMaxTouchCount < 2) {
            if (self.controlUnderCursorTouch == TUCControlUnderTouchPending
                && [[NSDate date] timeIntervalSinceDate:self.cursorTouchBeganDate] < kControlLookupWait) {
                return; // the answer is usually back within a few milliseconds
            }
            if (self.controlUnderCursorTouch == TUCControlUnderTouchDraggable && self.dragsControlsDirectly) {
                [self beginControlDrag];
                return;
            }
        }
        [self performMouseEventForGesture:TUCCursorGestureDrag];
    }
}


#pragma mark - Controls Under the Finger

/**
 Accessibility calls go to the app under the finger and can be slow, so they run on their own queue.
 */
- (void)lookUpControlAtLocation:(CGPoint)location {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("TouchMyMac.controlLookup", DISPATCH_QUEUE_SERIAL);
    });

    NSInteger session = ++self.controlLookupSession;
    self.controlUnderCursorTouch = TUCControlUnderTouchPending;
    self.controlPressLocation = location;
    BOOL assists = self.assistsSmallTargets;
    CGFloat splitterReach = assists ? kSplitterReachMM * [[self touchscreen] pixelsPerMM] : 0;
    CGFloat titleBarHeight = assists ? kTitleBarBandPoints : 0;
    CGFloat windowButtonReach = assists ? kWindowButtonReachMM * [[self touchscreen] pixelsPerMM] : 0;
    __weak typeof(self) weakSelf = self;
    dispatch_async(queue, ^{
        CGPoint pressLocation = location;
        CGPoint buttonLocation = location;
        BOOL nearWindowButton = windowButtonReach > 0 && TUCFindNearbyWindowButton(location, windowButtonReach, &buttonLocation);
        BOOL draggable = TUCDraggableControlAtLocation(location, splitterReach, titleBarHeight, &pressLocation);
        BOOL onDesktopBar = assists && draggable && TUCIsOnMissionControlDesktopBar(location);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf.controlLookupSession == session && strongSelf.controlUnderCursorTouch == TUCControlUnderTouchPending) {
                strongSelf.controlUnderCursorTouch = draggable ? TUCControlUnderTouchDraggable : TUCControlUnderTouchOther;
                strongSelf.controlPressLocation = pressLocation;
                strongSelf.fingerOnDesktopBar = onDesktopBar;
                strongSelf.hasWindowButtonTapLocation = nearWindowButton;
                strongSelf.windowButtonTapLocation = buttonLocation;
                if (onDesktopBar && strongSelf.cursorTouch != nil) {
                    [strongSelf holdOptionForDesktopBar];
                }
            }
        });
    });
}

/**
 The finger moved on a control that follows a drag. Press where it landed (or on the divider it
 landed next to), so the control moves with the finger from there, and keep dragging until liftoff.
 */
- (void)beginControlDrag {
    self.cursorTouchDidHold = YES;
    [[TUCCursorUtilities sharedInstance] dragCursorTo:self.controlPressLocation phase:NSTouchPhaseBegan];
    self.lastPerformedAction = TUCCursorActionDrag;
    [self performMouseEventForGesture:TUCCursorGestureHoldAndDrag];
}

/**
 Mission Control draws a desktop's close button only after the pointer rests on the desktop, which a
 touch never does, so a tap on the button switched to the desktop instead. Holding Option shows every
 close button at once; it's held while a finger is on the row of desktops.
 */
- (void)holdOptionForDesktopBar {
    if (self.holdingOptionForDesktopBar) {
        return;
    }
    self.holdingOptionForDesktopBar = YES;
    self.optionDownDate = [NSDate date];
    TUCPostOptionKey(true);
}

- (void)releaseOptionForDesktopBar {
    if (!self.holdingOptionForDesktopBar) {
        return;
    }
    self.holdingOptionForDesktopBar = NO;
    TUCPostOptionKey(false);
}

/// Releases Option once a click that was just posted has finished.
- (void)releaseOptionForDesktopBarSoon {
    if (!self.holdingOptionForDesktopBar) {
        return;
    }
    NSDate *downDate = self.optionDownDate;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.optionDownDate == downDate) { // not held again by a newer touch
            [weakSelf releaseOptionForDesktopBar];
        }
    });
}

static void TUCPostOptionKey(bool down) {
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, 58 /* kVK_Option */, down);
    if (event != NULL) {
        CGEventSetFlags(event, down ? kCGEventFlagMaskAlternate : 0);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
    }
}

/// Whether the cursor finger has stayed a possible tap for the hold duration, making it a long press.
- (BOOL)cursorTouchReachedHold {
    return self.cursorTouchQualifiedForTap && !self.cursorTouchDidHold && self.sessionMaxTouchCount < 2
        && !self.cursorTouchStoppedMomentum // a touch that stopped inertia is not pressing anything
        && self.cursorTouchBeganDate != nil
        && [[NSDate date] timeIntervalSinceDate:self.cursorTouchBeganDate] >= self.holdDuration;
}

/// A long press: the mouse goes down where the finger landed. Moving on drags (selecting text, moving
/// files, windows in Mission Control) and lifting releases, which is a click if the finger didn't move.
- (void)beginLongPress {
    [self pressAtLandingLocation];
    if ([self.delegate respondsToSelector:@selector(touchDidBeginLongPressAtScreenLocation:)]) {
        self.longPressFeedbackShown = YES;
        [self.delegate touchDidBeginLongPressAtScreenLocation:[self convertScreenPointRelativeToAbsolute:self.cursorTouchStartLocation]];
    }
}

/// Presses the mouse button where the cursor finger landed; later moves drag and liftoff releases.
- (void)pressAtLandingLocation {
    self.cursorTouchDidHold = YES;
    [[TUCCursorUtilities sharedInstance] dragCursorTo:[self convertScreenPointRelativeToAbsolute:self.cursorTouchStartLocation]
                                                phase:NSTouchPhaseBegan];
    self.lastPerformedAction = TUCCursorActionDrag;
}

static NSString *TUCCopyRole(AXUIElementRef element) {
    CFTypeRef role = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXRoleAttribute, &role) != kAXErrorSuccess || role == NULL) {
        return nil;
    }
    if (CFGetTypeID(role) != CFStringGetTypeID()) {
        CFRelease(role);
        return nil;
    }
    return (__bridge_transfer NSString *)role;
}

/// Controls that follow a drag wherever they are in the hierarchy.
static BOOL TUCRoleFollowsDrag(NSString *role) {
    static NSSet<NSString *> *roles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        roles = [NSSet setWithArray:@[(__bridge NSString *)kAXSliderRole, (__bridge NSString *)kAXScrollBarRole,
                                      (__bridge NSString *)kAXValueIndicatorRole, (__bridge NSString *)kAXSplitterRole,
                                      (__bridge NSString *)kAXColorWellRole, (__bridge NSString *)kAXLevelIndicatorRole]];
    });
    return role != nil && [roles containsObject:role];
}

/**
 Whether the element right under the finger is a bare part of the window that drags: the title bar or
 a divider. Since macOS 26 the title bar is the window's toolbar, or the title text sitting on the
 window, and a split view's divider shows up as the split group itself, where no pane covers it.
 */
static BOOL TUCElementUnderFingerFollowsDrag(NSString *role, NSString *parentRole) {
    if ([role isEqualToString:(__bridge NSString *)kAXWindowRole]
        || [role isEqualToString:(__bridge NSString *)kAXToolbarRole]
        || [role isEqualToString:(__bridge NSString *)kAXSplitGroupRole]) {
        return YES;
    }
    return [role isEqualToString:(__bridge NSString *)kAXStaticTextRole]
        && [parentRole isEqualToString:(__bridge NSString *)kAXWindowRole];
}

static CGRect TUCCopyFrame(AXUIElementRef element) {
    CGPoint origin = CGPointZero;
    CGSize size = CGSizeZero;
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXPositionAttribute, &value) == kAXErrorSuccess && value != NULL) {
        AXValueGetValue((AXValueRef)value, kAXValueTypeCGPoint, &origin);
        CFRelease(value);
    } else {
        return CGRectNull;
    }
    if (AXUIElementCopyAttributeValue(element, kAXSizeAttribute, &value) == kAXErrorSuccess && value != NULL) {
        AXValueGetValue((AXValueRef)value, kAXValueTypeCGSize, &size);
        CFRelease(value);
    } else {
        return CGRectNull;
    }
    return (CGRect){origin, size};
}

static AXUIElementRef TUCCopyParent(AXUIElementRef element) {
    CFTypeRef parent = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXParentAttribute, &parent) != kAXErrorSuccess) {
        return NULL;
    }
    return (AXUIElementRef)parent;
}

/// The point of `rect` nearest to `point`.
static CGPoint TUCClampToRect(CGPoint point, CGRect rect) {
    return CGPointMake(MIN(MAX(point.x, CGRectGetMinX(rect)), CGRectGetMaxX(rect)),
                       MIN(MAX(point.y, CGRectGetMinY(rect)), CGRectGetMaxY(rect)));
}

/// The press point on a divider's centre line, across from `location`.
static CGPoint TUCPressPointOnDivider(CGRect frame, CGPoint location) {
    CGPoint nearest = TUCClampToRect(location, frame);
    return CGRectGetWidth(frame) <= CGRectGetHeight(frame)
        ? CGPointMake(CGRectGetMidX(frame), nearest.y)
        : CGPointMake(nearest.x, CGRectGetMidY(frame));
}

/**
 Dividers are a few points wide, narrower than a fingertip lands, and some can't be hit-tested at all:
 Chrome reports a page's overlay instead of the divider under it (Overleaf). So this looks for one by
 its frame. A divider sits beside the panels it separates, so going up from the element under the
 finger, it looks a few levels into each ancestor's other children, skipping any that don't come
 within `reach` points of `location`, and moves `pressLocation` onto the nearest divider within `reach`.
 */
static BOOL TUCFindNearbySplitter(AXUIElementRef element, CGPoint location, CGFloat reach, CGPoint *pressLocation) {
    static const int kMaxLevelsUp = 12;
    static const NSUInteger kMaxChecked = 200; // keeps the search to a few milliseconds in a large web page
    static const int kSideBranchDepth = 5; // web pages nest a divider a few wrappers deep

    BOOL found = NO;
    __block CGFloat bestDistance = reach;
    CGRect area = CGRectMake(location.x - reach, location.y - reach, 2 * reach, 2 * reach);
    __block NSUInteger checked = 0;

    // Checks `node`; looks inside it `depth` more levels if it comes near the finger.
    __block BOOL (^check)(AXUIElementRef node, int depth);
    BOOL (^checkNode)(AXUIElementRef, int) = ^BOOL(AXUIElementRef node, int depth) {
        if (checked >= kMaxChecked) {
            return NO;
        }
        checked++;
        CGRect frame = TUCCopyFrame(node);
        if (!CGRectIsNull(frame) && !CGRectIntersectsRect(frame, area)) {
            return NO; // nothing in here comes close to the finger
        }
        NSString *role = TUCCopyRole(node);
        if ([role isEqualToString:(__bridge NSString *)kAXSplitterRole]) {
            if (!CGRectIsNull(frame)) {
                CGPoint nearest = TUCClampToRect(location, frame);
                CGFloat distance = hypot(nearest.x - location.x, nearest.y - location.y);
                if (distance <= bestDistance) {
                    bestDistance = distance;
                    *pressLocation = TUCPressPointOnDivider(frame, location);
                    return YES;
                }
            }
            return NO;
        }
        if (depth == 0) {
            return NO;
        }
        BOOL foundInside = NO;
        CFTypeRef children = NULL;
        if (AXUIElementCopyAttributeValue(node, kAXChildrenAttribute, &children) == kAXErrorSuccess && children != NULL) {
            if (CFGetTypeID(children) == CFArrayGetTypeID()) {
                for (id child in (__bridge NSArray *)children) {
                    foundInside = check((__bridge AXUIElementRef)child, depth - 1) || foundInside;
                }
            }
            CFRelease(children);
        }
        return foundInside;
    };
    check = checkNode;

    AXUIElementRef below = NULL; // the ancestor's child on the way up, already searched
    AXUIElementRef current = TUCCopyParent(element);
    for (int level = 0; level < kMaxLevelsUp && current != NULL && checked < kMaxChecked; level++) {
        NSString *role = TUCCopyRole(current);
        if ([role isEqualToString:(__bridge NSString *)kAXApplicationRole]) {
            break;
        }
        CFTypeRef children = NULL;
        if (AXUIElementCopyAttributeValue(current, kAXChildrenAttribute, &children) == kAXErrorSuccess && children != NULL) {
            if (CFGetTypeID(children) == CFArrayGetTypeID()) {
                for (id child in (__bridge NSArray *)children) {
                    if (below != NULL && CFEqual((__bridge CFTypeRef)child, below)) {
                        continue;
                    }
                    found = check((__bridge AXUIElementRef)child, kSideBranchDepth) || found;
                }
            }
            CFRelease(children);
        }
        if (found || [role isEqualToString:(__bridge NSString *)kAXWindowRole]) {
            break; // the closest level with a divider has it
        }
        if (below != NULL) {
            CFRelease(below);
        }
        below = current;
        current = TUCCopyParent(current);
    }
    if (below != NULL) {
        CFRelease(below);
    }
    if (current != NULL) {
        CFRelease(current);
    }
    check = nil;
    return found;
}

/**
 Dividers that web pages and Electron apps draw themselves (Claude's sidebar edge, for one) are
 reported as splitters but not inside a split view, and only part of their frame takes clicks.
 Hit-tests points to the left and right of `location`, up to `reach` points away, and moves
 `pressLocation` onto the nearest one that lands on a splitter.
 */
static BOOL TUCProbeForSplitter(AXUIElementRef systemWide, CGPoint location, CGFloat reach, CGPoint *pressLocation) {
    // Rings of probes 3 points apart, so a divider whose hit area is only a few points wide isn't skipped.
    const CGFloat step = 3;
    // Only sideways: side panels are by far the most common, and each direction costs a probe per ring.
    const CGFloat directions[] = {-1, 1};
    for (CGFloat distance = step; distance <= reach + 0.5 * step; distance += step) {
        BOOL found = NO;
        CGFloat bestDistance = CGFLOAT_MAX;
        for (int d = 0; d < 2; d++) {
            CGPoint probe = CGPointMake(location.x + directions[d] * distance, location.y);
            AXUIElementRef element = NULL;
            if (AXUIElementCopyElementAtPosition(systemWide, probe.x, probe.y, &element) != kAXErrorSuccess || element == NULL) {
                continue;
            }
            if ([TUCCopyRole(element) isEqualToString:(__bridge NSString *)kAXSplitterRole]) {
                CGRect frame = TUCCopyFrame(element);
                if (!CGRectIsNull(frame)) {
                    CGPoint nearest = TUCClampToRect(location, frame);
                    CGFloat away = hypot(nearest.x - location.x, nearest.y - location.y);
                    if (away < bestDistance) {
                        bestDistance = away;
                        // Press where the probe hit it: that point is known to reach the divider.
                        *pressLocation = probe;
                        found = YES;
                    }
                }
            }
            CFRelease(element);
        }
        if (found) {
            return YES; // a closer ring wins
        }
    }
    return NO;
}

/// The Accessibility window for a window from CGWindowListCopyWindowInfo, matched by owner and frame. Retained.
static AXUIElementRef TUCCopyAXWindowForWindowInfo(NSDictionary *info, CGRect frame) {
    pid_t pid = [info[(__bridge NSString *)kCGWindowOwnerPID] intValue];
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(app, 0.05);
    AXUIElementRef match = NULL;
    CFTypeRef axWindows = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &axWindows) == kAXErrorSuccess && axWindows != NULL) {
        if (CFGetTypeID(axWindows) == CFArrayGetTypeID()) {
            for (id candidate in (__bridge NSArray *)axWindows) {
                CGRect axFrame = TUCCopyFrame((__bridge AXUIElementRef)candidate);
                if (!CGRectIsNull(axFrame) && fabs(axFrame.origin.x - frame.origin.x) <= 1 && fabs(axFrame.origin.y - frame.origin.y) <= 1
                    && fabs(axFrame.size.width - frame.size.width) <= 1 && fabs(axFrame.size.height - frame.size.height) <= 1) {
                    match = (AXUIElementRef)CFRetain((__bridge CFTypeRef)candidate);
                    break;
                }
            }
        }
        CFRelease(axWindows);
    }
    CFRelease(app);
    return match;
}

/// Whether the element under `location` is something clickable other than a window's own buttons.
static BOOL TUCIsOtherControlAtLocation(CGPoint location) {
    static AXUIElementRef systemWide;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        systemWide = AXUIElementCreateSystemWide();
        AXUIElementSetMessagingTimeout(systemWide, 0.05);
    });
    AXUIElementRef element = NULL;
    if (AXUIElementCopyElementAtPosition(systemWide, location.x, location.y, &element) != kAXErrorSuccess || element == NULL) {
        return NO;
    }
    BOOL other = NO;
    CFTypeRef subrole = NULL;
    BOOL isWindowButton = NO;
    if (AXUIElementCopyAttributeValue(element, kAXSubroleAttribute, &subrole) == kAXErrorSuccess && subrole != NULL) {
        if (CFGetTypeID(subrole) == CFStringGetTypeID()) {
            NSString *name = (__bridge NSString *)subrole;
            isWindowButton = [name isEqualToString:(__bridge NSString *)kAXCloseButtonSubrole]
                || [name isEqualToString:(__bridge NSString *)kAXMinimizeButtonSubrole]
                || [name isEqualToString:(__bridge NSString *)kAXZoomButtonSubrole]
                || [name isEqualToString:(__bridge NSString *)kAXFullScreenButtonSubrole];
        }
        CFRelease(subrole);
    }
    if (!isWindowButton) {
        CFArrayRef actions = NULL;
        if (AXUIElementCopyActionNames(element, &actions) == kAXErrorSuccess && actions != NULL) {
            other = CFArrayContainsValue(actions, CFRangeMake(0, CFArrayGetCount(actions)), kAXPressAction);
            CFRelease(actions);
        }
    }
    CFRelease(element);
    return other;
}

/**
 A window's close, minimize and zoom buttons are about 14 points across, smaller than a fingertip
 lands. If `location` is within `reach` points of one of the frontmost nearby window's buttons,
 `buttonLocation` is the centre of the nearest one, so a tap there clicks it.
 */
static BOOL TUCFindNearbyWindowButton(CGPoint location, CGFloat reach, CGPoint *buttonLocation) {
    CFArrayRef windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (windows == NULL) {
        return NO;
    }
    BOOL found = NO;
    for (NSDictionary *info in (__bridge NSArray *)windows) {
        if ([info[(__bridge NSString *)kCGWindowLayer] integerValue] != 0
            || [info[(__bridge NSString *)kCGWindowAlpha] doubleValue] <= 0) {
            continue;
        }
        CGRect frame;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(__bridge NSString *)kCGWindowBounds], &frame)
            || !CGRectContainsPoint(CGRectInset(frame, -reach, -reach), location)) {
            continue;
        }
        // The frontmost window that close to the finger decides. Its buttons sit in its top-left
        // corner, so skip the Accessibility calls anywhere else.
        if (location.y - CGRectGetMinY(frame) > 60 || location.x - CGRectGetMinX(frame) > 120) {
            break;
        }
        if (TUCIsOtherControlAtLocation(location)) {
            break; // the finger is on a control of its own, such as a toolbar button beside them
        }
        AXUIElementRef axWindow = TUCCopyAXWindowForWindowInfo(info, frame);
        if (axWindow == NULL) {
            break;
        }
        CGFloat bestDistance = reach;
        const CFStringRef attributes[] = {kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute};
        for (int i = 0; i < 3; i++) {
            CFTypeRef button = NULL;
            if (AXUIElementCopyAttributeValue(axWindow, attributes[i], &button) != kAXErrorSuccess || button == NULL) {
                continue;
            }
            if (CFGetTypeID(button) == AXUIElementGetTypeID()) {
                CGRect buttonFrame = TUCCopyFrame((AXUIElementRef)button);
                Boolean enabled = true;
                CFTypeRef enabledValue = NULL;
                if (AXUIElementCopyAttributeValue((AXUIElementRef)button, kAXEnabledAttribute, &enabledValue) == kAXErrorSuccess && enabledValue != NULL) {
                    enabled = CFGetTypeID(enabledValue) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)enabledValue);
                    CFRelease(enabledValue);
                }
                if (enabled && !CGRectIsNull(buttonFrame) && CGRectGetWidth(buttonFrame) > 0) {
                    CGPoint nearest = TUCClampToRect(location, buttonFrame);
                    CGFloat distance = hypot(nearest.x - location.x, nearest.y - location.y);
                    if (distance <= bestDistance) {
                        bestDistance = distance;
                        *buttonLocation = CGPointMake(CGRectGetMidX(buttonFrame), CGRectGetMidY(buttonFrame));
                        found = YES;
                    }
                }
            }
            CFRelease(button);
        }
        CFRelease(axWindow);
        break;
    }
    CFRelease(windows);
    return found;
}

/**
 Window edges resize only within about 3 points of the edge line, and corners only close to the
 rounded corner: much less than a fingertip's accuracy. If `location` is within `reach` points
 outside a resizable window's edge, or `inside` points inside it, `pressLocation` moves onto the edge
 line (or onto the corner, near both edges) so dragging resizes the window. The window is the
 frontmost one that comes that close to the finger.
 */
static BOOL TUCFindNearbyWindowEdge(CGPoint location, CGFloat reach, CGFloat inside, CGFloat cornerInside, CGPoint *pressLocation) {
    CFArrayRef windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (windows == NULL) {
        return NO;
    }
    BOOL found = NO;
    for (NSDictionary *info in (__bridge NSArray *)windows) {
        if ([info[(__bridge NSString *)kCGWindowLayer] integerValue] != 0
            || [info[(__bridge NSString *)kCGWindowAlpha] doubleValue] <= 0) {
            continue;
        }
        CGRect frame;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(__bridge NSString *)kCGWindowBounds], &frame)
            || !CGRectContainsPoint(CGRectInset(frame, -reach, -reach), location)) {
            continue;
        }
        // This is the frontmost window that close to the finger; whatever it says decides.
        CGFloat dxLeft = location.x - CGRectGetMinX(frame), dxRight = CGRectGetMaxX(frame) - location.x;
        CGFloat dyTop = location.y - CGRectGetMinY(frame), dyBottom = CGRectGetMaxY(frame) - location.y;
        // Distance inside the window from each edge (negative outside).
        CGFloat nearX = MIN(dxLeft, dxRight), nearY = MIN(dyTop, dyBottom);
        BOOL nearCorner = nearX <= cornerInside && nearY <= cornerInside;
        BOOL nearEdge = nearX <= inside || nearY <= inside;
        if (!nearCorner && !nearEdge) {
            break; // on the window's content
        }
        // Only a window that can be resized and isn't full screen.
        BOOL resizable = NO;
        AXUIElementRef axWindow = TUCCopyAXWindowForWindowInfo(info, frame);
        if (axWindow != NULL) {
            Boolean settable = false;
            AXUIElementIsAttributeSettable(axWindow, kAXSizeAttribute, &settable);
            CFTypeRef fullScreen = NULL;
            BOOL isFullScreen = NO;
            if (AXUIElementCopyAttributeValue(axWindow, CFSTR("AXFullScreen"), &fullScreen) == kAXErrorSuccess && fullScreen != NULL) {
                isFullScreen = CFGetTypeID(fullScreen) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)fullScreen);
                CFRelease(fullScreen);
            }
            resizable = settable && !isFullScreen;
            CFRelease(axWindow);
        }
        if (!resizable) {
            break;
        }
        CGPoint press = location;
        if (nearCorner || nearX <= inside) {
            press.x = dxLeft < dxRight ? CGRectGetMinX(frame) : CGRectGetMaxX(frame);
        }
        if (nearCorner || nearY <= inside) {
            press.y = dyTop < dyBottom ? CGRectGetMinY(frame) : CGRectGetMaxY(frame);
        }
        *pressLocation = press;
        found = YES;
        break;
    }
    CFRelease(windows);
    return found;
}

/**
 Whether `location` is in the title bar band at the top of a window that isn't full screen. Apps such
 as Electron ones show their whole window to Accessibility as one web area, so the title bar can only
 be found by where it is. Nothing there scrolls, so a drag there presses and drags.
 */
static BOOL TUCIsInTitleBarBand(AXUIElementRef element, CGPoint location, CGFloat bandHeight) {
    CFTypeRef window = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXWindowAttribute, &window) != kAXErrorSuccess || window == NULL) {
        return NO;
    }
    BOOL inBand = NO;
    if (CFGetTypeID(window) == AXUIElementGetTypeID()) {
        CFTypeRef fullScreen = NULL;
        BOOL isFullScreen = NO;
        if (AXUIElementCopyAttributeValue((AXUIElementRef)window, CFSTR("AXFullScreen"), &fullScreen) == kAXErrorSuccess && fullScreen != NULL) {
            isFullScreen = CFGetTypeID(fullScreen) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)fullScreen);
            CFRelease(fullScreen);
        }
        CGRect frame = TUCCopyFrame((AXUIElementRef)window);
        inBand = !isFullScreen && !CGRectIsNull(frame) && CGRectContainsPoint(frame, location)
            && location.y - CGRectGetMinY(frame) <= bandHeight;
    }
    CFRelease(window);
    return inBand;
}

/// Whether `element` belongs to WindowManager, which draws Mission Control and Stage Manager.
static BOOL TUCElementBelongsToWindowManager(AXUIElementRef element) {
    pid_t pid = 0;
    if (AXUIElementGetPid(element, &pid) != kAXErrorSuccess || pid <= 0) {
        return NO;
    }
    static pid_t windowManagerPID = 0;
    if (pid == windowManagerPID) {
        return YES;
    }
    NSString *bundleID = [NSRunningApplication runningApplicationWithProcessIdentifier:pid].bundleIdentifier;
    if ([bundleID isEqualToString:@"com.apple.WindowManager"]) {
        windowManagerPID = pid; // it keeps its process until it restarts
        return YES;
    }
    return NO;
}

static BOOL TUCElementCanRemoveDesktop(AXUIElementRef element) {
    CFArrayRef actions = NULL;
    if (AXUIElementCopyActionNames(element, &actions) != kAXErrorSuccess || actions == NULL) {
        return NO;
    }
    BOOL can = CFArrayContainsValue(actions, CFRangeMake(0, CFArrayGetCount(actions)), CFSTR("AXRemoveDesktop"));
    CFRelease(actions);
    return can;
}

/// Whether `element` or something up to `depth` levels inside it is a Mission Control desktop.
static BOOL TUCElementHoldsDesktop(AXUIElementRef element, int depth) {
    if (TUCElementCanRemoveDesktop(element)) {
        return YES;
    }
    if (depth == 0) {
        return NO;
    }
    BOOL holds = NO;
    CFTypeRef children = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &children) == kAXErrorSuccess && children != NULL) {
        if (CFGetTypeID(children) == CFArrayGetTypeID()) {
            for (id child in (__bridge NSArray *)children) {
                if (TUCElementHoldsDesktop((__bridge AXUIElementRef)child, depth - 1)) {
                    holds = YES;
                    break;
                }
            }
        }
        CFRelease(children);
    }
    return holds;
}

/**
 Whether `location` is on Mission Control's row of desktops: on a desktop, or on the row around them
 (the Spaces Bar holds a list that holds the desktops).
 */
static BOOL TUCIsOnMissionControlDesktopBar(CGPoint location) {
    static AXUIElementRef systemWide;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        systemWide = AXUIElementCreateSystemWide();
        AXUIElementSetMessagingTimeout(systemWide, 0.05);
    });
    AXUIElementRef element = NULL;
    if (AXUIElementCopyElementAtPosition(systemWide, location.x, location.y, &element) != kAXErrorSuccess || element == NULL) {
        return NO;
    }
    BOOL onBar = TUCElementBelongsToWindowManager(element) && TUCElementHoldsDesktop(element, 2);
    if (!onBar && TUCElementBelongsToWindowManager(element)) {
        // Something inside a desktop, such as its label.
        AXUIElementRef parent = TUCCopyParent(element);
        onBar = parent != NULL && TUCElementCanRemoveDesktop(parent);
        if (parent != NULL) {
            CFRelease(parent);
        }
    }
    CFRelease(element);
    return onBar;
}

/**
 Whether a drag starting at `location` (global display coordinates) should press and drag rather than
 scroll: on a control that follows a drag, a split view divider within `splitterReach` points, or the
 title bar. `pressLocation` is where to press, which differs from `location` when snapping to a divider.
 */
static BOOL TUCDraggableControlAtLocation(CGPoint location, CGFloat splitterReach, CGFloat titleBarHeight, CGPoint *pressLocation) {
    static AXUIElementRef systemWide;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        systemWide = AXUIElementCreateSystemWide();
        AXUIElementSetMessagingTimeout(systemWide, 0.05); // an app that doesn't answer shouldn't hold up scrolling
    });
    *pressLocation = location;

    AXUIElementRef underFinger = NULL;
    if (AXUIElementCopyElementAtPosition(systemWide, location.x, location.y, &underFinger) != kAXErrorSuccess || underFinger == NULL) {
        return NO;
    }

    // Mission Control (and Stage Manager) belong to WindowManager. Nothing there scrolls, and windows
    // and desktops are dragged around, so a drag there always presses. This comes before the window
    // edges, which still report where the windows were before Mission Control shrank them.
    if (TUCElementBelongsToWindowManager(underFinger)) {
        CFRelease(underFinger);
        return YES;
    }

    if (splitterReach > 0 && TUCFindNearbyWindowEdge(location, splitterReach, kWindowEdgeInsidePoints, kWindowCornerInsidePoints, pressLocation)) {
        CFRelease(underFinger);
        return YES;
    }

    // The element under the finger, or one of its two parents, follows a drag (a slider's knob, a scroll bar).
    BOOL draggable = NO;
    NSString *underFingerRole = TUCCopyRole(underFinger);
    NSString *parentRole = nil;
    AXUIElementRef current = (AXUIElementRef)CFRetain(underFinger);
    for (int depth = 0; depth < 3 && current != NULL; depth++) {
        NSString *role = depth == 0 ? underFingerRole : TUCCopyRole(current);
        if (depth == 1) {
            parentRole = role;
        }
        draggable = draggable || TUCRoleFollowsDrag(role)
            || (depth == 1 && TUCElementUnderFingerFollowsDrag(underFingerRole, role));
        AXUIElementRef parent = TUCCopyParent(current);
        CFRelease(current);
        current = parent;
        if (depth == 0 && current == NULL) {
            draggable = draggable || TUCElementUnderFingerFollowsDrag(underFingerRole, nil);
        }
    }
    if (current != NULL) {
        CFRelease(current);
    }

    // A divider close by takes the drag, even from a scroll bar running along it (Finder's sidebar
    // scroll bar overlaps its divider and is usually hidden on a touchscreen), but not from a slider.
    // In the gap between a split view's panes, a divider further off is still the one meant.
    BOOL onSlider = [underFingerRole isEqualToString:(__bridge NSString *)kAXSliderRole]
        || [parentRole isEqualToString:(__bridge NSString *)kAXSliderRole];
    BOOL inSplitGap = [underFingerRole isEqualToString:(__bridge NSString *)kAXSplitGroupRole];
    if (!onSlider && splitterReach > 0
        && TUCFindNearbySplitter(underFinger, location, inSplitGap ? 3 * splitterReach : splitterReach, pressLocation)) {
        draggable = YES;
    }

    if (!draggable && titleBarHeight > 0) {
        draggable = TUCIsInTitleBarBand(underFinger, location, titleBarHeight);
    }
    if (!draggable && !onSlider && splitterReach > 0) {
        draggable = TUCProbeForSplitter(systemWide, location, splitterReach, pressLocation);
    }
    CFRelease(underFinger);
    return draggable;
}


#pragma mark - Multi-Finger Gestures

/**
 Active touches including claimed ones (e.g. fingers on the floating keyboard), for multi-finger gestures.
 */
- (NSSet<TUCTouch *> *)allActiveTouches {
    NSMutableSet<TUCTouch *> *active = [NSMutableSet setWithCapacity:self.touchSet.count];
    for (TUCTouch *touch in self.touchSet) {
        if (touch.isActive) {
            [active addObject:touch];
        }
    }
    return active;
}

/**
 Called once per report. A finger count only counts once it lasts a few reports, so a contact that drops
 out and comes back under a new ID (briefly one finger too many) can't turn four fingers into five.
 */
- (void)updateGestureFingerCountWithTouches:(NSArray<TUCTouch *> *)touches {
    NSInteger count = (NSInteger)touches.count;
    if (count == self.lastReportTouchCount) {
        self.lastReportTouchCountRepeats += 1;
    } else {
        self.lastReportTouchCount = count;
        self.lastReportTouchCountRepeats = 1;
    }

    // Enough fingers on the keyboard to be a gesture: tell it right away, before its keys commit.
    if (!self.claimedTouchesBecameGesture && (NSUInteger)count >= kClaimedGestureFingerCount) {
        for (TUCTouch *touch in touches) {
            if (touch.isClaimed) {
                self.claimedTouchesBecameGesture = YES;
                [self.delegate claimedTouchesDidBecomeGesture];
                break;
            }
        }
    }

    if (self.lastReportTouchCountRepeats < kStableTouchCountReports || count <= self.gestureFingerCount) {
        return;
    }

    if (count >= 3 && self.gestureFingerCount < 3) {
        [self abandonOneAndTwoFingerActions];
        self.multiFingerTravel = CGPointZero;
        self.multiFingerLastCentroidCount = 0;
    }
    self.gestureFingerCount = count;
}

/**
 Once three or more fingers are down, whatever one or two fingers were doing (scroll, drag, pinch,
 a possible tap) is over for the rest of the session.
 */
- (void)abandonOneAndTwoFingerActions {
    [self stopCurrentGesture];
    self.suppressEndedPrimaryTouchAction = YES;
    self.cursorTouchDidHold = NO;
    self.twoFingerTapPossible = NO;
    self.pendingTwoFingerTap = NO;
}

- (void)resetMultiFingerSession {
    [self endSpaceSwipe];
    [self resetFiveFingerHoldTracking];
    self.gestureFingerCount = 0;
    self.lastReportTouchCount = 0;
    self.lastReportTouchCountRepeats = 0;
    self.multiFingerTravel = CGPointZero;
    self.multiFingerLastCentroidCount = 0;
    self.multiFingerGestureTriggered = NO;
    self.claimedTouchesBecameGesture = NO;
    self.debugThreeFingerTracking = NO;
    self.debugThreeFingerTriggered = NO;
    self.debugThreeFingerTouchCount = 0;
    self.debugThreeFingerUpwardTouchCount = 0;
    self.debugThreeFingerVerticalTravelMM = 0;
    self.debugThreeFingerHorizontalTravelMM = 0;
}

/**
 Returns YES while the session is a multi-finger gesture, so one- and two-finger handling stays off.
 */
- (BOOL)processMultiFingerGestureWithTouches:(NSArray<TUCTouch *> *)touches {
    if (self.gestureFingerCount < 3 || !self.postMouseEvents) {
        return NO;
    }

    // A finger dropping out or joining moves the centroid without any real movement,
    // so only frames with the same fingers as the last one add to the travel.
    CGPoint centroid = [self centroidForTouches:touches];
    if (touches.count > 0 && (NSInteger)touches.count == self.multiFingerLastCentroidCount) {
        self.multiFingerTravel = CGPointMake(self.multiFingerTravel.x + centroid.x - self.multiFingerLastCentroid.x,
                                             self.multiFingerTravel.y + centroid.y - self.multiFingerLastCentroid.y);
    }
    self.multiFingerLastCentroid = centroid;
    self.multiFingerLastCentroidCount = (NSInteger)touches.count;

    if (self.gestureFingerCount >= 4 && self.missionControlMayBeOpen) {
        return YES;
    }
    if (self.gestureFingerCount >= 5) {
        [self processFiveFingerHoldWithTouches:touches];
        return YES;
    }

    CGSize physicalSize = [self touchscreen].physicalSize;
    CGFloat rightMM = self.multiFingerTravel.x * physicalSize.width;
    CGFloat downMM = self.multiFingerTravel.y * physicalSize.height;

    if (self.gestureFingerCount == 3) {
        self.debugThreeFingerTracking = YES;
        self.debugThreeFingerTouchCount = touches.count;
        self.debugThreeFingerUpwardTouchCount = [self upwardTouchCountForTouches:touches hasDownward:NULL];
        self.debugThreeFingerVerticalTravelMM = -downMM;
        self.debugThreeFingerHorizontalTravelMM = fabs(rightMM);
    }

    if (self.spaceSwipeActive) {
        if (touches.count == 3) {
            [self updateSpaceSwipeWithTravelMM:rightMM];
        } else {
            [self endSpaceSwipe]; // a finger lifted: the swipe is over
        }
        return YES;
    }

    if (self.multiFingerGestureTriggered) {
        return YES;
    }

    TUCCursorGesture gesture = _TUCCursorGestureNone;
    if (self.gestureFingerCount == 3) {
        if (self.threeFingerSwipeEnabled && -downMM >= kThreeFingerSwipeTriggerTravelMM
            && fabs(rightMM) <= kThreeFingerSwipeMaxHorizontalTravelMM) {
            gesture = TUCCursorGestureThreeFingerSwipeUp;
            self.debugThreeFingerTriggered = YES;
        } else if (self.threeFingerSwipeSpacesEnabled && fabs(rightMM) >= kThreeFingerSwipeTriggerTravelMM
                   && fabs(downMM) <= MIN(kThreeFingerSwipeMaxVerticalTravelMM, fabs(rightMM) * 0.5)) {
            // Clearly sideways only, so a swipe up that drifts doesn't switch spaces instead of opening Mission Control.
            gesture = rightMM < 0 ? TUCCursorGestureThreeFingerSwipeLeft : TUCCursorGestureThreeFingerSwipeRight;
            self.debugThreeFingerTriggered = YES;
        }
    } else {
        BOOL mostlyVertical = fabs(rightMM) <= kFourFingerSwipeMaxCrossTravelMM;
        if (self.fourFingerSwipeUpKeyboardEnabled && mostlyVertical && -downMM >= kFourFingerSwipeTriggerTravelMM) {
            gesture = TUCCursorGestureFourFingerSwipeUp;
        } else if (self.fourFingerSwipeUpKeyboardEnabled && mostlyVertical && downMM >= kFourFingerSwipeTriggerTravelMM) {
            gesture = TUCCursorGestureFourFingerSwipeDown;
        } else if ([self isFourFingerSwipeLeftEnabledInCurrentConfig] && fabs(downMM) <= kFourFingerSwipeMaxCrossTravelMM
                   && -rightMM >= kFourFingerSwipeTriggerTravelMM) {
            gesture = TUCCursorGestureFourFingerSwipeLeft;
        }
    }

    if (gesture != _TUCCursorGestureNone) {
        self.multiFingerGestureTriggered = YES;
        if (gesture == TUCCursorGestureThreeFingerSwipeUp) {
            // The swipe toggles Mission Control, so a second one closes it.
            self.missionControlMayBeOpen = !self.missionControlMayBeOpen;
        }
        BOOL sideways = gesture == TUCCursorGestureThreeFingerSwipeLeft || gesture == TUCCursorGestureThreeFingerSwipeRight;
        if (sideways && [TUCCursorUtilities sharedInstance].canSwipeSpacesContinuously) {
            [self beginSpaceSwipeWithTravelMM:rightMM];
            return YES;
        }
        [self performMouseEventForGesture:gesture];
    }
    return YES;
}

#pragma mark - Space Swipes

/**
 Three fingers moving sideways move the spaces along with them, like on a trackpad: macOS shows the
 neighbouring space sliding in and springs back at the first or last space. On liftoff the switch
 finishes or springs back depending on how far and how fast the fingers went.
 */
- (void)beginSpaceSwipeWithTravelMM:(CGFloat)travelMM {
    self.missionControlMayBeOpen = NO;
    self.spaceSwipeActive = YES;
    self.spaceSwipeProgress = 0;
    self.spaceSwipeVelocity = 0;
    self.spaceSwipeLastMoveDate = [NSDate date];
    [[TUCCursorUtilities sharedInstance] beginSpaceSwipe];
    [self updateSpaceSwipeWithTravelMM:travelMM];
}

/// `travelMM` is how far the fingers moved right since they landed (negative: left). The spaces move
/// with the fingers, one screen width per screen width, and at most to the next space.
- (void)updateSpaceSwipeWithTravelMM:(CGFloat)travelMM {
    CGFloat widthMM = [self touchscreen].physicalSize.width;
    CGFloat progress = widthMM > 0 ? MAX(-1, MIN(1, travelMM / widthMM)) : 0;
    NSDate *now = [NSDate date];
    NSTimeInterval elapsed = [now timeIntervalSinceDate:self.spaceSwipeLastMoveDate];
    if (progress == self.spaceSwipeProgress) {
        return;
    }
    if (elapsed > 0.001) {
        CGFloat velocity = (progress - self.spaceSwipeProgress) / elapsed;
        self.spaceSwipeVelocity = 0.6 * velocity + 0.4 * self.spaceSwipeVelocity;
    }
    self.spaceSwipeProgress = progress;
    self.spaceSwipeLastMoveDate = now;
    [[TUCCursorUtilities sharedInstance] updateSpaceSwipeProgress:progress];
}

- (void)endSpaceSwipe {
    if (!self.spaceSwipeActive) {
        return;
    }
    self.spaceSwipeActive = NO;
    CGFloat velocity = self.spaceSwipeVelocity;
    if ([[NSDate date] timeIntervalSinceDate:self.spaceSwipeLastMoveDate] > kSpaceSwipeStillAfter) {
        velocity = 0; // the fingers had stopped before they lifted
    }
    // macOS switches whenever the swipe ends and springs back when it's cancelled, so the decision is
    // made here, as a trackpad does: switch once dragged a quarter of the way or flicked onwards, unless the
    // fingers were flicking back.
    CGFloat progress = self.spaceSwipeProgress;
    CGFloat onwardSpeed = progress >= 0 ? velocity : -velocity;
    BOOL flickedOnward = onwardSpeed >= kSpaceSwipeFlingVelocity && fabs(progress) >= kSpaceSwipeFlingMinProgress;
    BOOL flickedBack = onwardSpeed <= -kSpaceSwipeFlingBackVelocity;
    BOOL switches = !flickedBack && (flickedOnward || fabs(progress) >= kSpaceSwipeCommitProgress);
    [[TUCCursorUtilities sharedInstance] endSpaceSwipeWithVelocity:velocity cancelled:!switches];
}

- (void)processFiveFingerHoldWithTouches:(NSArray<TUCTouch *> *)touches {
    if (![self isFiveFingerHoldEnabledInCurrentConfig] || touches.count != 5) {
        [self resetFiveFingerHoldTracking];
        return;
    }

    CGPoint centroid = [self centroidForTouches:touches];
    if (!self.fiveFingerHoldTracking) {
        self.fiveFingerHoldTracking = YES;
        self.fiveFingerHoldActivated = NO;
        self.fiveFingerHoldStartCentroid = centroid;
        self.fiveFingerHoldStartDate = [NSDate date];
    }
    if (self.fiveFingerHoldActivated) {
        return;
    }

    if ([self distanceMMFromPoint:centroid toPoint:self.fiveFingerHoldStartCentroid] > kFiveFingerHoldMaxTravelMM) {
        self.fiveFingerHoldStartCentroid = centroid;
        self.fiveFingerHoldStartDate = [NSDate date];
    } else if ([[NSDate date] timeIntervalSinceDate:self.fiveFingerHoldStartDate] >= kFiveFingerHoldActivationDuration) {
        [self performMouseEventForGesture:TUCCursorGestureFiveFingerHold];
        self.fiveFingerHoldActivated = YES;
    }
}


#pragma mark - Two-Finger Tap

- (BOOL)anyTouchMovedFromInitialLocation:(NSArray<TUCTouch *> *)touches {
    for (TUCTouch *touch in touches) {
        if ([self distanceMMFromPoint:touch.location toPoint:touch.initialLocation] > kTapSlopMM) {
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
        self.missionControlMayBeOpen = NO;
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
    
    // A tap clicks where the finger landed: a finger drifts a little as it flattens and lifts.
    CGPoint screenLocation = [self convertScreenPointRelativeToAbsolute:
                              gesture == TUCCursorGestureTap ? self.cursorTouchStartLocation : touch.location];
    if (gesture == TUCCursorGestureTap && self.hasWindowButtonTapLocation) {
        screenLocation = self.windowButtonTapLocation; // the close, minimize or zoom button it landed beside
    }
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
    
    CGFloat pointsPerMM = [[self touchscreen] pixelsPerMM];
    [[TUCCursorUtilities sharedInstance] setDoubleClickTolerance:self.doubleClickTolerance * pointsPerMM];
    utils.momentumPointsPerMM = pointsPerMM;
    
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
            self.missionControlMayBeOpen = NO; // a click closes Mission Control
            [utils performClickAt:screenLocation];
            break;
            
        case TUCCursorActionSecondaryClick:
            self.missionControlMayBeOpen = NO;
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
            if (touch.phase == NSTouchPhaseEnded || touch.phase == NSTouchPhaseCancelled) {
                // The pointer (hidden while scrolling) reappears where the finger lifted, not where it landed.
                // Apps keep the scroll and its inertia on the view it started in.
                [utils movePointerKeepingScrollTo:screenLocation];
            }
            [utils scroll:scaledTranslation phase:touch.phase];
            
            if (touch.phase == NSTouchPhaseEnded || touch.phase == NSTouchPhaseCancelled) {
                self.hasLastScrollLocation = NO;
            }
            
            break; }
            
        case TUCCursorActionMagnify: {
            CGFloat span = (CGFloat)hypot(screenLocation.x - location2ndFinger.x, screenLocation.y - location2ndFinger.y);
            CGPoint center = CGPointMake((screenLocation.x + location2ndFinger.x) / 2, (screenLocation.y + location2ndFinger.y) / 2);
            [utils updatePinchSpan:span center:center];
            
            if (touch.phase == NSTouchPhaseEnded || self.gestureAdditionalTouch.phase == NSTouchPhaseEnded) {
                [utils stopMagnifying];
            }
            break; }

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

        case TUCCursorActionSwitchToLeftSpace:
            [utils switchSpaceToRight:NO];
            break;

        case TUCCursorActionSwitchToRightSpace:
            [utils switchSpaceToRight:YES];
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
        // Like a trackpad, the content follows the fingers: swiping left brings in the space on the right.
        case TUCCursorGestureThreeFingerSwipeLeft: return TUCCursorActionSwitchToRightSpace;
        case TUCCursorGestureThreeFingerSwipeRight:return TUCCursorActionSwitchToLeftSpace;
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
        
        self.currentFrameID = 0;
        self.identifiedMultitouchGesture = _TUCCursorGestureNone;
        
        self.doubleClickTolerance = 5;
        self.holdDuration = 0.4;
        self.assistsSmallTargets = YES;
        self.errorResistance = 0;
        
        self.ignoreOriginTouches = NO;

        self.scrollInertiaEnabled = YES;
        self.hidesCursorWhileScrolling = YES;
        self.scrollInertiaDecelerationPerFrame = 0.92;
        self.scrollInertiaVelocityMultiplier = 1.0;
        self.scrollSpeedMultiplier = 1.0;
        self.pinchZoomSpeed = 1.5;
        self.threeFingerSwipeEnabled = YES;
        self.threeFingerSwipeSpacesEnabled = YES;
        self.dragsControlsDirectly = YES;
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

- (void)setPinchZoomSpeed:(CGFloat)pinchZoomSpeed {
    _pinchZoomSpeed = pinchZoomSpeed;
    [TUCCursorUtilities sharedInstance].pinchZoomExponent = pinchZoomSpeed;
}

- (void)setHidesCursorWhileScrolling:(BOOL)hidesCursorWhileScrolling {
    _hidesCursorWhileScrolling = hidesCursorWhileScrolling;
    [TUCCursorUtilities sharedInstance].hidesCursorWhileScrolling = hidesCursorWhileScrolling;
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
