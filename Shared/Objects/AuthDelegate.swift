//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2022 Jellyfin & Jellyfin Contributors
//

import Factory
import Foundation

class AuthDelegate: NSObject, URLSessionDelegate {
    @Injected(LogManager.service)
    var logger

    var identity: SecIdentity?

    init(identity: SecIdentity? = nil) {
        self.identity = identity
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        logger.trace(
            "challenge.protectionSpace.authenticationMethod=\(challenge.protectionSpace.authenticationMethod)",
            tag: "AuthDelegate:urlSession"
        )
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate else {
            logger.trace("not client auth", tag: "AuthDelegate:urlSession")
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard challenge.previousFailureCount == 0 else {
            logger.debug("previously failed", tag: "AuthDelegate:urlSession")
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let _identity = self.identity else {
            logger.debug("no identity", tag: "AuthDelegate:urlSession")
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let credential = URLCredential(identity: _identity, certificates: nil, persistence: .forSession)

        logger.trace("handled", tag: "AuthDelegate:urlSession")
        completionHandler(.useCredential, credential)
    }
}
