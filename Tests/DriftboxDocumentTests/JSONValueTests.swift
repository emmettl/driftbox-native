import DriftboxDocument
import Testing

struct JSONValueTests {
  /// Laid out as `Number::toString` lays them out. The expectations are what Node prints.
  @Test(arguments: [
    (0.0, "0"), (-0.0, "0"), (1, "1"), (-1, "-1"), (120, "120"), (0.72, "0.72"),
    (0.1 + 0.2, "0.30000000000000004"), (1e21, "1e+21"), (1e20, "100000000000000000000"),
    (1.2345678901234568e20, "123456789012345680000"), (1e-6, "0.000001"), (1e-7, "1e-7"),
    (1.5e-7, "1.5e-7"), (-2.5e-9, "-2.5e-9"), (5e-324, "5e-324"),
    (1.7976931348623157e308, "1.7976931348623157e+308"),
    (0.11904761904761904, "0.11904761904761904"), (4_294_967_296, "4294967296"),
    (0.000123, "0.000123"), (100.5, "100.5"),
  ])
  func numbersPrintAsJavaScriptPrintsThem(value: Double, expected: String) {
    #expect(JSONValue.number(value).text == expected)
  }

  @Test func keysStayInDocumentOrderAndARepeatKeepsItsFirstPlace() throws {
    let value = try #require(JSONValue(parsing: #"{"z":1,"a":2,"z":3}"#))
    #expect(value.text == #"{"z":3,"a":2}"#)
  }

  @Test(arguments: [
    "", "{", "[1,]", #"{"a":1,}"#, "01", "1.", ".5", "+1", "nul", #""unterminated"#,
    #""bad \x escape""#, "[1] trailing", "\"a raw \u{9} tab\"",
  ])
  func refusesWhatJSONParseRefuses(text: String) {
    #expect(JSONValue(parsing: text) == nil)
  }

  @Test func stringsSurviveEscapesAndSurrogatePairs() throws {
    let text = #"["a\"b\\c\/d\n\u00e9\ud83e\udd41\u0001"]"#
    let value = try #require(JSONValue(parsing: text))
    #expect(value.array?.first?.string == "a\"b\\c/d\n\u{e9}\u{1F941}\u{1}")
    // Written back, only what must be escaped is: the rest goes out as itself.
    #expect(value.text == "[\"a\\\"b\\\\c/d\\n\u{e9}\u{1F941}\\u0001\"]")
  }
}
