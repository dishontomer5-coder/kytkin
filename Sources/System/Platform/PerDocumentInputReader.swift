// P2-19: Reads macOS "Automatically switch to a document's input source" (research input-source-switching.md §4).
// READ-ONLY: CFPreferencesCopyAppValue only. Kytkin never sets a value in com.apple.HIToolbox or the global
// domain (design.md: never change system settings). The mapping to on/off is in Core `PerDocumentInputPref`.
//
// Freshness: CFPreferences caches another app's domain in-process, so a change made in System Settings could
// be missed. `CFPreferencesAppSynchronize` drops that cache; it can only flush values *this process* set in
// the domain, and Kytkin never sets any, so nothing is ever written.

import CoreFoundation

enum PerDocumentInputReader {
    @MainActor static func isEnabled() -> Bool {
        let key = PerDocumentInputPref.dictionaryKey as CFString
        let domain = PerDocumentInputPref.domain as CFString
        CFPreferencesAppSynchronize(domain)
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let hiToolbox = CFPreferencesCopyAppValue(key, domain)
        let global = CFPreferencesCopyAppValue(key, kCFPreferencesAnyApplication)
        return PerDocumentInputPref.isEnabled(hiToolbox: hiToolbox as Any?, global: global as Any?)
    }
}
