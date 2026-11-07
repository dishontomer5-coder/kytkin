// P2-20: KeyWatcher already has every member of Core's `KeyWatching`; this only declares the conformance, so
// AppController (Core) can drive it and its tests can use a fake instead.

import Foundation

extension KeyWatcher: KeyWatching {}
