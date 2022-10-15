//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2022 Jellyfin & Jellyfin Contributors
//

import Foundation

class CertificateManager {
    public static func loadP12(uri: String, passphrase: String) throws -> SecIdentity? {
        let data = try Data(contentsOf: URL(string: uri)!)
        let options = [kSecImportExportPassphrase as String: passphrase]
        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess else {
            LogManager.service().warning("Unknown status: \(status)", tag: "certificateManager:loadP12")
            return nil
        }

        guard let itemsCFArray = rawItems else {
            LogManager.service().warning("rawItems invalid", tag: "certificateManager:loadP12")
            return nil
        }

        let items = itemsCFArray as NSArray
        guard let dictArray = items as? [[String: AnyObject]] else {
            LogManager.service().warning("items invalid", tag: "certificateManager:loadP12")
            return nil
        }

        guard let identity: SecIdentity = readKey(key: kSecImportItemIdentity, dictArray: dictArray) else {
            LogManager.service().warning("Missing SecIdentity", tag: "certificateManager:loadP12")
            return nil
        }

        LogManager.service().debug("Success", tag: "certificateManager:loadP12")
        return identity
    }

    // Returns errSecSuccess or errSecDuplicateItem on success
    public static func addIdentityToStore(identity: SecIdentity, labelPrefix: String) -> OSStatus {
        LogManager.service().debug("Adding cert with prefix: \(labelPrefix)", tag: "certificateManager:addIdentityToStore")
        var cert: SecCertificate?
        var status = SecIdentityCopyCertificate(identity, &cert)
        guard status == errSecSuccess else {
            let statusString = SecCopyErrorMessageString(status, nil) ?? "Unknown" as CFString
            LogManager.service().warning("Invalid status1: \(status) \(statusString)", tag: "certificateManager:addIdentityToStore")
            return status
        }

        var privateKey: SecKey?
        status = SecIdentityCopyPrivateKey(identity, &privateKey)
        guard status == errSecSuccess else {
            let statusString = SecCopyErrorMessageString(status, nil) ?? "Unknown" as CFString
            LogManager.service().warning("Invalid status2: \(status) \(statusString)", tag: "certificateManager:addIdentityToStore")
            return status
        }

        var addquery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert as Any,
            kSecAttrLabel as String: "\(labelPrefix)_cert",
        ]

        status = SecItemAdd(addquery as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            let statusString = SecCopyErrorMessageString(status, nil) ?? "Unknown" as CFString
            LogManager.service().warning("Invalid status3: \(status) \(statusString)", tag: "certificateManager:addIdentityToStore")
            return status
        }

        // Update label of existing item. Doesn't currently support the same cert for multiple hosts.
        // TODO: instead of labels, store id to cert in coredata: kSecAttrCertificateType, kSecAttrIssuer, kSecAttrSerialNumber
        if status == errSecDuplicateItem {
            let updatequery: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: cert as Any,
            ]
            let updateattributes: [String: String] = [
                kSecAttrLabel as String: "\(labelPrefix)_cert",
            ]
            status = SecItemUpdate(updatequery as CFDictionary, updateattributes as CFDictionary)
            guard status == errSecSuccess else {
                let statusString = SecCopyErrorMessageString(status, nil) ?? "Unknown" as CFString
                LogManager.service().warning("Invalid status3.1: \(status) \(statusString)", tag: "certificateManager:addIdentityToStore")
                return status
            }
        }

        addquery = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: privateKey as Any,
            kSecAttrLabel as String: "\(labelPrefix)_key",
        ]

        status = SecItemAdd(addquery as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            let statusString = SecCopyErrorMessageString(status, nil) ?? "Unknown" as CFString
            LogManager.service().warning("Invalid status4: \(status) \(statusString)", tag: "certificateManager:addIdentityToStore")
            return status
        }

        // Update label of existing item
        if status == errSecDuplicateItem {
            let updatequery: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecValueRef as String: privateKey as Any,
            ]
            let updateattributes: [String: String] = [
                kSecAttrLabel as String: "\(labelPrefix)_key",
            ]
            status = SecItemUpdate(updatequery as CFDictionary, updateattributes as CFDictionary)
            guard status == errSecSuccess else {
                let statusString = SecCopyErrorMessageString(status, nil) ?? "Unknown" as CFString
                LogManager.service().warning("Invalid status4.1: \(status) \(statusString)", tag: "certificateManager:addIdentityToStore")
                return status
            }
        }

        LogManager.service().debug("Success", tag: "certificateManager:addIdentityToStore")
        return status
    }

    public static func getIdentityFromStore(labelPrefix: String) -> SecIdentity? {
        LogManager.service().trace("Loading cert with prefix: \(labelPrefix)", tag: "certificateManager:getIdentityFromStore")
        let getquery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: "\(labelPrefix)_cert",
            kSecReturnRef as String: true,
        ]
        var maybeItem: CFTypeRef?
        let status = SecItemCopyMatching(getquery as CFDictionary, &maybeItem)
        guard status == errSecSuccess else {
            let statusString = SecCopyErrorMessageString(status, nil) ?? "Unknown" as CFString
            LogManager.service().warning("Invalid status: \(status) \(statusString)", tag: "certificateManager:getIdentityFromStore")
            return nil
        }

        guard let item = maybeItem else {
            LogManager.service().warning("Missing item", tag: "certificateManager:getIdentityFromStore")
            return nil
        }

        let identity = item as! SecIdentity
        LogManager.service().trace("Success", tag: "certificateManager:getIdentityFromStore")
        return identity
    }

    static func readKey<T>(key: CFString, dictArray: [[String: AnyObject]]) -> T? {
        for dict in dictArray {
            if let value = dict[key as String] as? T {
                return value
            }
        }
        return nil
    }
}
