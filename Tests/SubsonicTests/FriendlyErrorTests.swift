import Foundation
import Testing
@testable import Subsonic

@Suite struct FriendlyErrorTests {
    @Test func httpStatus() {
        #expect(SubsonicError.badStatus(500).friendlyMessage == "The server had a problem (error 500). Try again later.")
        for status in [502, 503, 504] {
            #expect(SubsonicError.badStatus(status).friendlyMessage == "The server is not available now (error \(status)). Try again later.")
        }
        #expect(SubsonicError.badStatus(418).friendlyMessage.contains("error 418"))
    }

    @Test func subsonicCodes() {
        for code in [10, 20, 30, 40, 41, 50, 60, 70] {
            let message = SubsonicError.api(code: code, message: "raw text").friendlyMessage
            #expect(!message.contains("raw text") && message.hasSuffix("."), "code \(code)")
        }
        #expect(SubsonicError.api(code: 40, message: "x").friendlyMessage == "Wrong user name or password. Check them in Settings.")
        // Unknown codes keep the server's own words.
        #expect(SubsonicError.api(code: 0, message: "Index out of range").friendlyMessage.contains("Index out of range"))
    }

    @Test func network() {
        #expect(URLError(.timedOut).friendlyMessage.hasPrefix("The server did not answer in time."))
        #expect(URLError(.cannotFindHost).friendlyMessage.hasPrefix("Cannot find the server."))
        #expect(URLError(.dnsLookupFailed).friendlyMessage.hasPrefix("Cannot find the server."))
        #expect(URLError(.cannotConnectToHost).friendlyMessage.hasPrefix("The server refused the connection."))
        for code: URLError.Code in [.secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate] {
            #expect(URLError(code).friendlyMessage.hasPrefix("Cannot make a secure connection"))
        }
        #expect(SubsonicError.badResponse("getAlbum: junk").friendlyMessage.hasPrefix("The server sent a reply"))
    }

    /// Other errors keep their own text.
    @Test func otherErrors() {
        #expect(CocoaError(.fileNoSuchFile).friendlyMessage == CocoaError(.fileNoSuchFile).localizedDescription)
    }
}
