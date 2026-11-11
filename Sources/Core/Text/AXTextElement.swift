// P2-18: One focused text element, readable and writable through the AX seam.

import Foundation

/// P2-59c: also an identity (`FocusedElementIdentity`), for same-element checks.
protocol AXTextElement: AXElementReading, AXElementWriting, FocusedElementIdentity {}
