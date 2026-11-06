// P2-18: The write half of the AX seam. Every write the replacer makes is read back and verified
// (design.md invariant); an AX "success" alone is never trusted (R5).

import Foundation

protocol AXElementWriting: AnyObject {
    func setString(_ value: String, for attribute: AXTextAttribute) -> Result<Void, AXAccessError>
    func setRange(_ value: TextRange, for attribute: AXTextAttribute) -> Result<Void, AXAccessError>
}
