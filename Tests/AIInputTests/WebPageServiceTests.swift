import XCTest
@testable import AIInput

final class WebPageServiceTests: XCTestCase {
    func testValidatedURLAcceptsHTTPSAndRejectsOtherSchemes() throws {
        let url = try WebPageService.validatedHTTPSURL(
            from: " https://example.com/article?id=7#section "
        )
        let upgradedURL = try WebPageService.validatedHTTPSURL(
            from: "http://example.com/article"
        )
        let upgradedDefaultPortURL = try WebPageService.validatedHTTPSURL(
            from: "http://example.com:80/article"
        )

        XCTAssertEqual(url.absoluteString, "https://example.com/article?id=7")
        XCTAssertEqual(upgradedURL.absoluteString, "https://example.com/article")
        XCTAssertEqual(upgradedDefaultPortURL.absoluteString, "https://example.com/article")
        XCTAssertThrowsError(try WebPageService.validatedHTTPSURL(from: "file:///tmp/article.html"))
        XCTAssertThrowsError(try WebPageService.validatedHTTPSURL(from: "https:///missing-host"))
        XCTAssertThrowsError(try WebPageService.validatedHTTPSURL(from: "https://user:pass@example.com"))
        XCTAssertThrowsError(try WebPageService.validatedHTTPSURL(from: "https://localhost/page"))
        XCTAssertThrowsError(try WebPageService.validatedHTTPSURL(from: "https://127.0.0.1/page"))
        XCTAssertThrowsError(try WebPageService.validatedHTTPSURL(from: "https://192.168.1.4/page"))
        XCTAssertThrowsError(try WebPageService.validatedHTTPSURL(from: "https://198.18.0.246/page"))
        XCTAssertThrowsError(try WebPageService.validatedHTTPSURL(from: "https://[::1]/page"))
    }

    func testHTMLExtractorPrefersArticleAndRemovesPageChromeAndUnsafeElements() throws {
        let html = """
        <html>
          <head><title>Example &amp; Guide</title></head>
          <body>
            <nav>Navigation should disappear</nav>
            <main><p>Main fallback should not win.</p></main>
            <article>
              <h1>Main &amp; Story</h1>
              <p>First&nbsp;paragraph.</p>
              <script>window.bad = "Script should disappear";</script>
              <div>Second &#169; line.</div>
            </article>
            <footer>Footer should disappear</footer>
          </body>
        </html>
        """

        let article = try HTMLArticleExtractor.extract(
            html: html,
            sourceURL: URL(string: "https://example.com/article")!
        )

        XCTAssertEqual(article.title, "Example & Guide")
        XCTAssertEqual(
            article.body,
            "Main & Story\n\nFirst paragraph.\n\nSecond © line."
        )
    }

    func testHTMLExtractorFallsBackFromMainToBody() throws {
        let main = try HTMLArticleExtractor.extract(
            html: "<html><main><p>Main text.</p></main><aside>Skip.</aside></html>",
            sourceURL: URL(string: "https://example.com/main")!
        )
        let body = try HTMLArticleExtractor.extract(
            html: "<html><body><header>Skip.</header><p>Body text.</p></body></html>",
            sourceURL: URL(string: "https://example.com/body")!
        )

        XCTAssertEqual(main.body, "Main text.")
        XCTAssertEqual(body.body, "Body text.")
    }

    func testHTMLExtractorSkipsEmptyArticleAndChoosesLongestArticle() throws {
        let fallback = try HTMLArticleExtractor.extract(
            html: "<html><article></article><main><p>Actual main text.</p></main></html>",
            sourceURL: URL(string: "https://example.com/fallback")!
        )
        let longest = try HTMLArticleExtractor.extract(
            html: """
            <html><body>
              <article><p>Short card.</p></article>
              <article><p>This is the substantially longer article body.</p></article>
            </body></html>
            """,
            sourceURL: URL(string: "https://example.com/longest")!
        )
        let recommendation = String(repeating: "Card content. ", count: 11)
        let mainBody = String(repeating: "Actual article paragraph. ", count: 80)
        let scored = try HTMLArticleExtractor.extract(
            html: """
            <html><body>
              <article><p>\(recommendation)</p></article>
              <main><p>\(mainBody)</p></main>
            </body></html>
            """,
            sourceURL: URL(string: "https://example.com/scored")!
        )

        XCTAssertEqual(fallback.body, "Actual main text.")
        XCTAssertEqual(longest.body, "This is the substantially longer article body.")
        XCTAssertEqual(
            scored.body,
            mainBody.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func testHTMLExtractorDoesNotTreatDecodedAngleEntitiesAsMarkup() throws {
        let article = try HTMLArticleExtractor.extract(
            html: "<html><article><p>2 &lt; 3 and 5 &gt; 4</p></article></html>",
            sourceURL: URL(string: "https://example.com/entities")!
        )

        XCTAssertEqual(article.body, "2 < 3 and 5 > 4")
    }

    func testFetchStopsStreamingResponseAboveLimit() async throws {
        let service = WebPageService(
            session: makeStubSession(),
            validatesConnectedAddresses: false
        )

        do {
            _ = try await service.fetchArticle(
                from: "https://93.184.216.34/oversized"
            )
            XCTFail("Expected pageTooLarge")
        } catch WebPageService.WebPageError.pageTooLarge {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchDoesNotFollowRedirectToPrivateAddress() async throws {
        let service = WebPageService(
            session: makeStubSession(),
            validatesConnectedAddresses: false
        )

        do {
            _ = try await service.fetchArticle(
                from: "https://93.184.216.34/redirect"
            )
            XCTFail("Expected the private redirect to be rejected")
        } catch {
            // Any request failure is acceptable here; returning private content is not.
        }
    }

    func testLiveFetchChecksTheConnectedPublicAddress() async throws {
        guard ProcessInfo.processInfo.environment["AIINPUT_RUN_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set AIINPUT_RUN_NETWORK_TESTS=1 to run the live HTTPS check.")
        }

        let article = try await WebPageService().fetchArticle(
            from: "https://example.com"
        )

        XCTAssertTrue(article.body.contains("Example Domain"))
    }

    func testChunkingPreservesParagraphOrderAndSplitsOversizedContentAtCharacterBoundaries() {
        XCTAssertEqual(
            WebPageService.chunk(
                text: "Alpha beta.\n\nGamma delta.\n\nEpsilon.",
                maxCharacters: 20
            ),
            ["Alpha beta.", "Gamma delta.", "Epsilon."]
        )
        XCTAssertEqual(
            WebPageService.chunk(text: "甲乙丙丁戊", maxCharacters: 2),
            ["甲乙", "丙丁", "戊"]
        )
    }

    private func makeStubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebPageStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class WebPageStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        if url.path == "/redirect" {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": "https://127.0.0.1/private"]
            )!
            let redirect = URLRequest(url: URL(string: "https://127.0.0.1/private")!)
            client?.urlProtocol(
                self,
                wasRedirectedTo: redirect,
                redirectResponse: response
            )
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path == "/oversized" {
            let chunk = Data(repeating: 65, count: 64 * 1_024)
            for _ in 0...WebPageService.maximumDownloadBytes / chunk.count {
                client?.urlProtocol(self, didLoad: chunk)
            }
        } else {
            client?.urlProtocol(
                self,
                didLoad: Data("<article>private content</article>".utf8)
            )
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
