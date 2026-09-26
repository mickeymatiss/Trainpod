import Foundation
// Host-only peripheral dependencies. Algorithms and model types are production sources.
// Mirror shared provider error cases for standalone host builds; no behavior is implemented here.
enum LiveTransitError: Error { case noDirections, payloadTooLarge, platformCapacityExceeded }
struct FileLogger { static let shared = FileLogger(); func log(_ text: String) {} }
