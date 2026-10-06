//
//  TUCTouchInputManager-C.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#include <CoreGraphics/CoreGraphics.h>

#ifndef TUCTouchInputManager_C_h
#define TUCTouchInputManager_C_h

void TouchInputManagerUpdateTouchPosition(void *self, CFIndex contactID, CGFloat x, CGFloat y, Boolean onSurface, Boolean isValid);

void TouchInputManagerUpdateTouchSize(void *self, CFIndex contactID, CGFloat width, CGFloat height, CGFloat azimuth);

// called after a full report (no partials in hybrid modes) was handled
void TouchInputManagerDidProcessReport(void *self);

// pen position is normalized (0...1) in digitizer orientation, pressure is 0...1
void TouchInputManagerUpdatePen(void *self, CGFloat x, CGFloat y, Boolean tip, Boolean inRange, CGFloat pressure, Boolean eraser);

void TouchInputManagerDidConnectTouchscreen(void *self);

void TouchInputManagerDidDisconnectTouchscreen(void *self);

#endif /* TUCTouchInputManager_C_h */
