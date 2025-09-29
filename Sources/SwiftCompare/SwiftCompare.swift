import ArgumentParser
import Foundation
import Polykit

@main
struct SwiftCompare: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swcompare",
        abstract: "Compare two lists and output common and unique elements.",
    )

    @Flag(name: .long, help: "Compare case-sensitively ('Apple' and 'apple' are different).")
    var caseSensitive = false

    @Flag(name: .long, help: "Skip asking for list titles.")
    var noTitles = false

    func run() throws {
        // Get list titles
        let title1 = noTitles ? "first" : getTitle("first")
        let title2 = noTitles ? "second" : getTitle("second")

        // Get the lists
        let list1 = getList(title: title1)
        let list2 = getList(title: title2)

        // Compare the lists
        let result = compareLists(list1, list2, caseSensitive: caseSensitive)

        // Display results
        displayResults(result, title1: title1, title2: title2)
    }

    /// Compares two lists and returns the common and unique elements.
    ///
    /// - Parameters:
    ///   - list1:         The first list to compare.
    ///   - list2:         The second list to compare.
    ///   - caseSensitive: Whether to compare the lists case-sensitively.
    /// - Returns: A ComparisonResult struct containing the common and unique elements.
    func compareLists(_ list1: [String], _ list2: [String], caseSensitive: Bool) -> ComparisonResult {
        let set1 = Set(list1.map { caseSensitive ? $0 : $0.lowercased() })
        let set2 = Set(list2.map { caseSensitive ? $0 : $0.lowercased() })

        let common = set1.intersection(set2)
        let unique1 = set1.subtracting(set2)
        let unique2 = set2.subtracting(set1)

        return ComparisonResult(
            common: Array(common), unique1: Array(unique1), unique2: Array(unique2),
        )
    }

    /// Struct containing the common and unique elements of two lists.
    ///
    /// - Parameters:
    ///   - common: The common elements of the two lists.
    ///   - unique1: The unique elements of the first list.
    ///   - unique2: The unique elements of the second list.
    struct ComparisonResult {
        let common: [String]
        let unique1: [String]
        let unique2: [String]
    }

    /// Gets the title of the list from the user.
    ///
    /// - Parameter defaultTitle: The default title to use if the user presses Enter.
    /// - Returns: The title of the list.
    func getTitle(_ defaultTitle: String) -> String {
        Text.printColor(
            "Enter a title for the \(defaultTitle) list (or press Enter to skip): ", .yellow,
            terminator: "",
        )
        if let input = readLine(), !input.isEmpty {
            return input
        }
        return defaultTitle
    }

    /// Gets the list from the user.
    ///
    /// - Parameter title: The title of the list.
    /// - Returns: The list.
    func getList(title: String) -> [String] {
        Text.printColor("\nPaste the \(title) list (type '.' and press Enter to finish):", .green)
        var items: [String] = []

        while let line = readLine() {
            if line == "." {
                break
            }
            items.append(line)
        }

        return items
    }

    /// Displays the results of the comparison.
    ///
    /// - Parameters:
    ///   - result: The result of the comparison.
    ///   - title1: The title of the first list.
    ///   - title2: The title of the second list.
    func displayResults(_ result: ComparisonResult, title1: String, title2: String) {
        Text.printColor("\n=== Results ===", .blue)

        Text.printColor("\nCommon elements (\(result.common.count)):", .yellow)
        for item in result.common.sorted() {
            Text.printColor("  • \(item)", .green)
        }

        Text.printColor("\nUnique in \(title1) list (\(result.unique1.count)):", .yellow)
        for item in result.unique1.sorted() {
            Text.printColor("  • \(item)", .green)
        }

        Text.printColor("\nUnique in \(title2) list (\(result.unique2.count)):", .yellow)
        for item in result.unique2.sorted() {
            Text.printColor("  • \(item)", .green)
        }
    }
}
