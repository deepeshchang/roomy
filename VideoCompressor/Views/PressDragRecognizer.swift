import SwiftUI
import UIKit

/// Press-and-hold, then drag: reports finger positions in a named coordinate
/// space.
///
/// UIKit, not a SwiftUI DragGesture, on purpose: on iOS 18 any SwiftUI drag
/// gesture inside a ScrollView's content blocks the scroll view — even as a
/// simultaneous gesture — which froze the library grid and swallowed taps.
/// UILongPressGestureRecognizer coexists with scrolling by design: a swipe
/// moves before the press is recognised, and a tap ends before it.
struct PressDragRecognizer: UIGestureRecognizerRepresentable {
    let coordinateSpace: String
    let onBegan: (CGPoint) -> Void
    let onChanged: (CGPoint) -> Void
    let onEnded: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.3
        recognizer.allowableMovement = 10
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer,
                                         context: Context) {
        let point = context.converter.location(in: .named(coordinateSpace))
        switch recognizer.state {
        case .began: onBegan(point)
        case .changed: onChanged(point)
        default: onEnded()
        }
    }
}
