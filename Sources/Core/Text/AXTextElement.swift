// P2-18: One focused text element, readable and writable through the AX seam.

import Foundation

/// P2-59c: also an identity (`FocusedElementIdentity`), for the undo record's same-element check.
protocol AXTextElement: AXElementReading, AXElementWriting, FocusedElementIdentity {}
