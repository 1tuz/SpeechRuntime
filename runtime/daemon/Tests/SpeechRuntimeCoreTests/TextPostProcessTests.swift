import Foundation
import XCTest
@testable import SpeechRuntimeCore

/// `POST /v1/text/postprocess`: service behaviour (auth, contract, limits) plus the
/// algorithm invariants — word boundaries, case handling, longest-match, no cascading,
/// literal replacement casing, conservative whitespace cleanup.
final class TextPostProcessTests: XCTestCase {
    // MARK: - Algorithm

    private func apply(_ text: String, _ rules: [(spoken: String, replacement: String)],
                       cleanup: Bool = false) -> String {
        TextPostProcess.apply(
            text,
            rules: rules.map { TextPostProcess.Rule(spoken: $0.spoken, replacement: $0.replacement) },
            cleanup: cleanup
        )
    }

    func testMultiWordPhraseReplacedMidSentence() {
        XCTAssertEqual(apply("разверни кубер нетис на проде", [("кубер нетис", "Kubernetes")]),
                       "разверни Kubernetes на проде")
    }

    func testMatchIsCaseInsensitiveReplacementIsLiteral() {
        XCTAssertEqual(apply("Разверни КУБЕР НЕТис сейчас", [("кубер нетис", "Kubernetes")]),
                       "Разверни Kubernetes сейчас")
        XCTAssertEqual(apply("Разверни КУБЕР НЕТис сейчас", [("кубер нетис", "kubernetes")]),
                       "Разверни kubernetes сейчас")
    }

    func testLiteralCasingSurvivesUppercaseMatch() {
        // Stored casing is the term's own; the transcript's casing never rewrites it.
        XCTAssertEqual(apply("Обнови ИОС", [("иос", "iOS")]), "Обнови iOS")
        XCTAssertEqual(apply("обнови иос", [("иос", "iOS")]), "обнови iOS")
        XCTAssertEqual(apply("Проверь МАКОС и линукс", [("макос", "macOS"), ("линукс", "GNU/Linux")]),
                       "Проверь macOS и GNU/Linux")
    }

    func testNoMatchInsideLongerWord() {
        XCTAssertEqual(apply("кубернетика интересна", [("кубер", "Kubernetes")]),
                       "кубернетика интересна")
        XCTAssertEqual(apply("деплоймент готов", [("деплой", "deploy")]), "деплоймент готов")
        XCTAssertEqual(apply("кубернетика, кубер и кубернетис", [("кубер", "Kubernetes")]),
                       "кубернетика, Kubernetes и кубернетис")
        XCTAssertEqual(apply("(кубер)", [("кубер", "Kubernetes")]), "(Kubernetes)")
    }

    func testHyphenatedChunkIsOneToken() {
        XCTAssertEqual(apply("кубер-кубер", [("кубер", "Kubernetes")]), "кубер-кубер")
    }

    func testTabIsATokenBoundary() {
        XCTAssertEqual(apply("кубер\tкубер", [("кубер", "Kubernetes")]), "Kubernetes\tKubernetes")
    }

    func testLatinTransliterationIsNotAMatch() {
        XCTAssertEqual(apply("deploy the kuber netis stack", [("кубер нетис", "Kubernetes")]),
                       "deploy the kuber netis stack")
    }

    func testEnglishSpellingFixApplies() {
        XCTAssertEqual(apply("the recieve bug", [("recieve", "receive")]), "the receive bug")
    }

    func testCyrillicRuleFiresInsideLatinSentence() {
        XCTAssertEqual(apply("deploy the кубер нетис stack", [("кубер нетис", "Kubernetes")]),
                       "deploy the Kubernetes stack")
    }

    func testNoCascadingReplacements() {
        XCTAssertEqual(apply("foo bar", [("foo", "bar"), ("bar", "baz")]), "bar baz")
        XCTAssertEqual(apply("фу бар", [("фу", "бар"), ("бар", "баз")]), "бар баз")
    }

    func testCaseOnlyRuleAppliesForEverySourceCasing() {
        // Case-only rules are ordinary rules: the replacement wins the span.
        XCTAssertEqual(apply("запусти кубер нетис", [("кубер нетис", "kubernetes")]),
                       "запусти kubernetes")
        XCTAssertEqual(apply("Запусти КУБЕР НЕТис", [("кубер нетис", "Kubernetes")]),
                       "Запусти Kubernetes")
        XCTAssertEqual(apply("Ios и macOS", [("ios", "iOS")]), "iOS и macOS")
        XCTAssertEqual(apply("IOS", [("ios", "iOS")]), "iOS")
        XCTAssertEqual(apply("ios", [("ios", "iOS")]), "iOS")
    }

    func testByteIdentityRuleRewritesTheSpanToItsOwnText() {
        // An ordinary identity rule is a client-side no-op: emitting its replacement
        // reproduces the matched span exactly, so nothing observable changes.
        XCTAssertEqual(apply("Kubernetes rocks", [("kubernetes", "Kubernetes")]),
                       "Kubernetes rocks")
        XCTAssertEqual(apply("KUBERNETES ROCKS", [("kubernetes", "Kubernetes")]),
                       "Kubernetes ROCKS",
                       "the rule is case-insensitive on the spoken side, as every rule is")
    }

    func testLongestRuleWinsAtSamePosition() {
        XCTAssertEqual(apply("кубер нетис", [("кубер", "Kubernetes"), ("кубер нетис", "Kubernetes")]),
                       "Kubernetes")
        XCTAssertEqual(apply("кубер и кубер нетис", [("кубер", "Kubernetes"), ("кубер нетис", "Kubernetes")]),
                       "Kubernetes и Kubernetes")
    }

    func testDuplicateSpokenSidesAreDeterministic() {
        XCTAssertEqual(apply("проверь постгрес", [("постгрес", "PostgreSQL"), ("постгрес", "Postgres")]),
                       "проверь PostgreSQL")
    }

    func testPhraseRuleRequiresAllTokensAdjacent() {
        // The tokens are adjacent elsewhere in the sentence, not consecutive there.
        XCTAssertEqual(apply("кубер на проде нетис", [("кубер нетис", "Kubernetes")]),
                       "кубер на проде нетис")
    }

    func testEmptyRulesLeaveTextUnchanged() {
        XCTAssertEqual(apply("кубер нетис", []), "кубер нетис")
    }

    // MARK: - Cleanup

    func testCleanupCollapsesSpaceAndTabRunsButKeepsLinebreaksAndPunctuation() {
        XCTAssertEqual(TextPostProcess.apply("  разверни   кубер,\n\n  на проде ",
            rules: [], cleanup: true), "разверни кубер,\n\n на проде")
        XCTAssertEqual(TextPostProcess.apply("hello\tworld", rules: [], cleanup: true), "hello world")
        XCTAssertEqual(TextPostProcess.apply("нет.  Точка", rules: [], cleanup: true), "нет. Точка")
        XCTAssertEqual(TextPostProcess.apply("первая строка\nвторая", rules: [], cleanup: true),
                       "первая строка\nвторая")
    }

    func testCleanupOffPreservesWhitespaceVerbatim() {
        XCTAssertEqual(TextPostProcess.apply("  разверни   кубер ", rules: [], cleanup: false),
                       "  разверни   кубер ")
    }

    func testEmptyAndWhitespaceOnlyTextIsIdentity() {
        XCTAssertEqual(TextPostProcess.apply("", rules: [], cleanup: true), "")
        XCTAssertEqual(TextPostProcess.apply("   ", rules: [], cleanup: true), "")
        XCTAssertEqual(TextPostProcess.apply("", rules: [], cleanup: false), "")
        XCTAssertEqual(TextPostProcess.apply("   ", rules: [], cleanup: false), "   ")
    }

    // MARK: - HTTP route

    private func router() -> Router {
        Router(
            token: AuthToken(value: "test-token"),
            worker: WorkerClient(workerPath: "/nonexistent/sr-worker") { _ in },
            config: { RuntimeConfig(jsonObject: [:]) },
            idle: IdlePolicy(),
            log: { _ in }
        )
    }

    private func request(_ method: String, _ path: String, json: Any? = nil,
                         authorized: Bool = true) -> HTTPRequest {
        var headers: [String: String] = [:]
        if authorized { headers["authorization"] = "Bearer test-token" }
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        return HTTPRequest(method: method, path: path, query: [:], headers: headers, body: body)
    }

    private func payload(_ response: HTTPResponse) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: response.body) as? [String: Any] ?? [:]
    }

    @MainActor
    func testRouteRequiresAuth() async throws {
        let response = await router().handle(request("POST", "/v1/text/postprocess",
            json: ["text": "кубер", "cleanup": false, "rules": []], authorized: false))
        XCTAssertEqual(response.status, 401)
        let wrongToken = HTTPRequest(
            method: "POST", path: "/v1/text/postprocess", query: [:],
            headers: ["authorization": "Bearer wrong"], body: Data())
        let wrong = await router().handle(wrongToken)
        XCTAssertEqual(wrong.status, 401)
    }

    @MainActor
    func testUnknownRouteKeepsCanonical404Body() async throws {
        let response = await router().handle(request("POST", "/v1/text/postprocess")
            .changing(path: "/v1/text/other"))
        XCTAssertEqual(response.status, 404)
        XCTAssertEqual(response.body, Data("{\"error\":\"no route for POST /v1/text/other\"}".utf8))
    }

    @MainActor
    func testRouteReturnsExactlyTextField() async throws {
        let response = await router().handle(request("POST", "/v1/text/postprocess",
            json: ["text": "разверни кубер нетис на проде", "cleanup": false,
                   "rules": [["spoken": "кубер нетис", "replacement": "Kubernetes"]]]))
        XCTAssertEqual(response.status, 200)
        let body = try payload(response)
        XCTAssertEqual(body["text"] as? String, "разверни Kubernetes на проде")
        XCTAssertEqual(Set(body.keys), ["text"], "the response carries exactly one field")
    }

    @MainActor
    func testMissingTextFieldIs400() async throws {
        let response = await router().handle(request("POST", "/v1/text/postprocess",
            json: ["cleanup": false, "rules": []]))
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual((try payload(response))["error"] as? String, "field \"text\" is required")
    }

    @MainActor
    func testPrefilteredRuleSetAppliesWithCleanup() async throws {
        // The app sends only its effective enabled rules; the endpoint does the rest.
        let response = await router().handle(request("POST", "/v1/text/postprocess",
            json: ["text": "  разверни    кубер нетис,\nна проде ", "cleanup": true,
                   "rules": [["spoken": "кубер нетис", "replacement": "Kubernetes"]]]))
        XCTAssertEqual(try payload(response)["text"] as? String, "разверни Kubernetes,\nна проде")
    }

    @MainActor
    func testOversizedInputIsRejectedNotSilentlyTrimmed() async throws {
        let longText = String(repeating: "а", count: TextPostProcess.Limits.textCharacters + 1)
        let response = await router().handle(request("POST", "/v1/text/postprocess",
            json: ["text": longText, "rules": []]))
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(((try payload(response))["error"] as? String ?? "").contains("limit is"))

        let tooMany: [[String: Any]] = (0...TextPostProcess.Limits.rules).map { index in
            ["spoken": "а\(index)", "replacement": "б"]
        }
        let response2 = await router().handle(request("POST", "/v1/text/postprocess",
            json: ["text": "текст", "rules": tooMany]))
        XCTAssertEqual(response2.status, 400)
        XCTAssertTrue(((try payload(response2))["error"] as? String ?? "").contains("exceeds the limit"))

        let response3 = await router().handle(request("POST", "/v1/text/postprocess",
            json: ["text": "текст", "rules": [["spoken": "а б в г д е ж з", "replacement": "x"]]]))
        XCTAssertEqual(response3.status, 400)
        XCTAssertTrue(((try payload(response3))["error"] as? String ?? "").contains("words"))
    }

    @MainActor
    func testRealisticMultiWordUtteranceWithMixedScripts() async throws {
        let text = "Запусти кубер нетис на проде, потом проверь постгре скью эль и задеплой ингрес"
        let rules: [[String: Any]] = [
            ["spoken": "кубер нетис", "replacement": "Kubernetes"],
            ["spoken": "постгре скью эль", "replacement": "PostgreSQL"],
            ["spoken": "ингрес", "replacement": "ingress"],
        ]
        let response = await router().handle(request("POST", "/v1/text/postprocess",
            json: ["text": text, "cleanup": true, "rules": rules]))
        XCTAssertEqual(try payload(response)["text"] as? String,
                       "Запусти Kubernetes на проде, потом проверь PostgreSQL и задеплой ingress")
    }
}

private extension HTTPRequest {
    func changing(path: String) -> HTTPRequest {
        HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }
}
