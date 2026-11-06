// P2-18: One focused text element, readable and writable through the AX seam.

import Foundation

protocol AXTextElement: AXElementReading, AXElementWriting {}
