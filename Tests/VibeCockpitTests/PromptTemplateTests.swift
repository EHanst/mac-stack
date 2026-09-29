import Testing
import Foundation
@testable import StackCore

@Suite("PromptTemplate")
struct PromptTemplateTests {

    @Test("lists variables once, in order")
    func variables() {
        #expect(PromptTemplate.variables(in: "Fix {{file}} then {{ target }} and {{file}} again") == ["file", "target"])
    }

    @Test("only non-built-in variables are asked for")
    func asked() {
        #expect(PromptTemplate.askedVariables(in: "{{selection}} {{goal}} {{date}}") == ["goal"])
    }

    @Test("renders values and leaves missing ones visible")
    func render() {
        let out = PromptTemplate.render("Do {{a}} to {{b}}", values: ["a": "X"])
        #expect(out == "Do X to {{b}}")
    }

    @Test("a value containing braces is not expanded again")
    func singlePass() {
        let out = PromptTemplate.render("{{a}} {{b}}", values: ["a": "{{b}}", "b": "SECRET"])
        #expect(out == "{{b}} SECRET")
    }

    @Test("stray braces and non-names are plain text")
    func plain() {
        let text = "func f() { let x = {{ }} ; {{1bad}} ; {single} ; {{ok"
        #expect(PromptTemplate.variables(in: text).isEmpty)
        #expect(PromptTemplate.render(text, values: [:]) == text)
    }
}
