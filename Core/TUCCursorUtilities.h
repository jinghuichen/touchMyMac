//
//  TUCCursorUtilities.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 11.02.23.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface TUCCursorUtilities : NSObject

+ (instancetype)sharedInstance;


@property CGFloat doubleClickTolerance;

/// Enables/disables inertial scrolling after a finger lifts.
@property (nonatomic) BOOL momentumScrollEnabled;

/// How quickly inertia slows down, in the old per-60Hz-frame terms (0.85-0.99). The default 0.92 gives
/// Android's scroll friction; higher values mean less friction and a longer glide.
@property (nonatomic) CGFloat momentumDecelerationPerFrame;

/// Scales how far and how long inertia glides (1.0 = Android). Inertia always starts at the release velocity.
@property (nonatomic) CGFloat momentumVelocityMultiplier;

/// Points per millimetre on the touchscreen, so inertia covers the same physical distance on any display.
@property (nonatomic) CGFloat momentumPointsPerMM;

/// Minimum finger velocity (px/s) needed to start inertial scrolling on liftoff.
@property (nonatomic) CGFloat momentumStartThreshold;

/// Hides the pointer while a finger scrolls, since scrolling leaves it where it was.
@property (nonatomic) BOOL hidesCursorWhileScrolling;

- (CGPoint)currentCursorLocation;

- (void)moveCursorTo:(CGPoint)aLocation;
/// Moves the pointer without ending a scroll or its inertia, e.g. to where a scrolling finger lifted.
- (void)movePointerKeepingScrollTo:(CGPoint)aLocation;

- (void)performClickAt:(CGPoint)aLocation;

- (void)performSecondaryClickAt:(CGPoint)aLocation;

- (void)dragCursorTo:(CGPoint)aLocation phase:(NSTouchPhase)phase;
- (void)stopDraggingCursor;

- (void)scroll:(CGPoint)translation phase:(NSTouchPhase)phase;
/// Ends an ongoing scroll gesture without inertia, e.g. when the touch turns into another gesture.
- (void)endScrollGesture;
@property (readonly) BOOL isMomentumScrolling;
/// Current inertia speed in points per second, 0 when inertia isn't running.
@property (readonly) CGFloat momentumScrollSpeed;

/// How far a pinch zooms: the finger-distance ratio is raised to this power (1 = exactly with the fingers).
@property (nonatomic) CGFloat pinchZoomExponent;

/// Pinching: the distance between the two fingers (points) and the point between them. The zoom follows
/// the ratio of distances, smoothed and posted once per display frame.
- (void)updatePinchSpan:(CGFloat)span center:(CGPoint)center;
- (void)stopMagnifying;

- (void)beginHoldingShortcutSpec:(NSString *)shortcutSpec;
- (void)endHeldShortcut;
- (void)performShortcutChordSpec:(NSString *)shortcutSpec;
- (void)performKeyCode:(CGKeyCode)keyCode modifierFlags:(CGEventFlags)flags;
- (void)performShortcutSequenceSpec:(NSString *)shortcutSequenceSpec;
- (void)performMissionControl;

/// Moves to the space on the right (YES) or left (NO), like Control-Right or Control-Left Arrow.
- (void)switchSpaceToRight:(BOOL)toRight;


@end

NS_ASSUME_NONNULL_END
