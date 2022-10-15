//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2022 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

class ServerDetailViewModel: ViewModel {

    @Published
    var server: SwiftfinStore.State.Server

    @Published
    var cert: SecCertificate?
    var hostname: String?

    init(server: SwiftfinStore.State.Server) {
        self.server = server
        if let hostname = URLComponents(string: server.currentURI)?.host,
           let identity = CertificateManager.getIdentityFromStore(labelPrefix: hostname)
        {
            self.cert = CertificateManager.getCertInfoFromIdentity(identity: identity)
            self.hostname = hostname
        }
    }

    func removeClientCert() {
        guard let hostname = self.hostname else { return }
        _ = CertificateManager.removeIdentityFromStore(labelPrefix: hostname)
    }

    func setServerCurrentURI(uri: String) {
        SessionManager.main.setServerCurrentURI(server: server, uri: uri)
            .sink { c in
                print(c)
            } receiveValue: { newServerState in
                self.server = newServerState

                Notifications[.didChangeServerCurrentURI].post(object: newServerState)
            }
            .store(in: &cancellables)
    }
}
