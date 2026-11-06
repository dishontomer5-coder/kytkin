// P2-18: The key-posting seam. The live adapter (`System/Text/CGEventKeyPoster`) turns each event into a
// CGEvent from a private event source with modifier flags cleared and posts it to the session stream.
// Unit tests record events instead. Never called on the tap thread (001 §2.1).

import Foundation

protocol KeyEventPosting: AnyObject {
    /// Posts one event. false = it wasn't posted (refused as unsafe, or the event couldn't be created).
    func post(_ event: SyntheticKeyEvent) -> Bool
}
