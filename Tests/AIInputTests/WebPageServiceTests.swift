import XCTest
@testable import AIInput

final class WebPageServiceTests: XCTestCase {
    func testValidatedURLAcceptsHTTPSAndRejectsOtherSchemes() throws {
        let url = try WebPageService.validatedHTTPSURL(
            from: " https://example.com/article?id=7#section "
        )

        XCTAssertEqual(url.absoluteString, "https://example.com/article?id=7")
        XCTAssertThrowsError(try WebPageService.validatedHTTPSURL(from: "http://example.com"))
        XCTAssertThrowsError(try WebPageService.validatedHTTPSURL(from: "file:///tmp/article.html"))
        XCTAssertThrowsError(try WebPageService.validatedHTTPSURL(from: "https:///missing-host"))
        XCTAssertThrowsError(try WebPageService.validatedHTTPSURL(from: "https://user:pass@example.com"))
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
}
