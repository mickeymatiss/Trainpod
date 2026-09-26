import Foundation
// Host-only peripheral dependencies. Algorithms and model types are production sources.
// LiveTransitError lives in the UIKit-dependent provider; no behavior is implemented here.
enum LiveTransitError: Error { case noDirections, payloadTooLarge, platformCapacityExceeded }
struct FileLogger { static let shared = FileLogger(); func log(_ text: String) {} }
