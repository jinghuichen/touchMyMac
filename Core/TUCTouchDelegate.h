//
//  TUCTouchDelegate.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import "TUCTouch.h"
#import "TUCScreen.h"

NS_ASSUME_NONNULL_BEGIN

@protocol TUCTouchDelegate <NSObject>

#pragma mark - Touch Data
/**
 
 This method is called every time after the `touchSet` was updated
 */
- (void)touchesDidChange;
- (void)inputDiagnosticsDidChange;



#pragma mark - Lifecycle

- (void)touchscreenDidConnect;
- (void)touchscreenDidDisconnect;



#pragma mark - Mouse Control

/**
 Specifies which screen corresponds to the touch screen.
 */
- (nullable TUCScreen *)touchscreen;

/**
 Used to customize which mouse events are posted by the input manager.
 */
- (TUCCursorAction)actionForGesture:(TUCCursorGesture)gesture;

/**
 Used for app-level actions that should not be performed inside TouchUpCore itself.
 */
- (void)performCustomAction:(TUCCursorAction)action;



#pragma mark - Claimed Touches

/**
 Called once for every new touch before any gesture recognition, with the location in global display coordinates.
 Return YES to claim the touch: it then never moves the cursor or takes part in gestures,
 and `claimedTouchDidEnd:` is called when it lifts.
 */
- (BOOL)shouldClaimTouch:(NSUUID *)touchID atScreenLocation:(CGPoint)location;

- (void)claimedTouchDidEnd:(NSUUID *)touchID;

@end

NS_ASSUME_NONNULL_END
