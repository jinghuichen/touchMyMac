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

/// Controls how quickly inertial scrolling slows down per 60Hz frame.
/// Default matches the built-in tuning.
@property (nonatomic) CGFloat momentumDecelerationPerFrame;

/// Multiplies the initial inertial velocity at liftoff (1.0 = unchanged).
@property (nonatomic) CGFloat momentumVelocityMultiplier;

/// Minimum finger velocity (px/s) needed to start inertial scrolling on liftoff.
@property (nonatomic) CGFloat momentumStartThreshold;

/// Velocity (px/s) below which inertial scrolling stops.
@property (nonatomic) CGFloat momentumVelocityStopThreshold;

- (CGPoint)currentCursorLocation;

- (void)moveCursorTo:(CGPoint)aLocation;

- (void)performClickAt:(CGPoint)aLocation;

- (void)performSecondaryClickAt:(CGPoint)aLocation;

- (void)dragCursorTo:(CGPoint)aLocation phase:(NSTouchPhase)phase;
- (void)stopDraggingCursor;

- (void)scroll:(CGPoint)translation phase:(NSTouchPhase)phase;
/// Ends an ongoing scroll gesture without inertia, e.g. when the touch turns into another gesture.
- (void)endScrollGesture;
@property (readonly) BOOL isMomentumScrolling;

- (void)magnifyLocationA:(CGPoint)p1 locationB:(CGPoint)p2 relativeP1:(CGPoint)r1 relP2:(CGPoint)r2;
- (void)stopMagnifying;

- (void)beginHoldingShortcutSpec:(NSString *)shortcutSpec;
- (void)endHeldShortcut;
- (void)performShortcutChordSpec:(NSString *)shortcutSpec;
- (void)performKeyCode:(CGKeyCode)keyCode modifierFlags:(CGEventFlags)flags;
- (void)performShortcutSequenceSpec:(NSString *)shortcutSequenceSpec;
- (void)performMissionControl;


@end

NS_ASSUME_NONNULL_END
