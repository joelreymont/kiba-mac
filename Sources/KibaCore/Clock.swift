import Foundation

/// The current time: production passes `Date.init`, tests a frozen instant.
public typealias Clock = @Sendable () -> Date
