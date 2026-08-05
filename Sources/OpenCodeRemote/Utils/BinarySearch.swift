import Foundation

// MARK: - BinarySearch

/// Binary search su array ordinati, come `Binary.search` del web
/// (usato da `confirmOptimistic` in `server-session.ts`).
public enum BinarySearch {
    /// Ritorna l'indice di `value` in `array` (ordinato crescentemente),
    /// oppure `nil` se assente. O(log n), niente `@unchecked`.
    public static func find<Element: Comparable>(_ array: [Element], _ value: Element) -> Int? {
        var low = 0
        var high = array.count - 1

        while low <= high {
            let mid = low + (high - low) / 2
            let current = array[mid]

            if current == value {
                return mid
            } else if current < value {
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return nil
    }
}
