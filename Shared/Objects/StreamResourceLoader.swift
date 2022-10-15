//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2022 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import Foundation

enum TlsLoaderError: Error {
    case runtimeError(String)
}

class RequestData {
    var loadingRequest: AVAssetResourceLoadingRequest
    var dataCount: Int64 = 0
    var utType: UTType?

    init(loadingRequest: AVAssetResourceLoadingRequest) {
        self.loadingRequest = loadingRequest
    }
}

class StreamUrlSessionDataDelegate: NSObject, URLSessionDataDelegate {
    var taskRequestMap: [Int: RequestData] = [:]
    var authDelegate: URLSessionDelegate?

    init(authDelegate: URLSessionDelegate? = nil) {
        self.authDelegate = authDelegate
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let requestData = taskRequestMap[dataTask.taskIdentifier] else { fatalError() }
        requestData.loadingRequest.dataRequest?.respond(with: data)
        requestData.dataCount += Int64(data.count)
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        fatalError()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let requestData = taskRequestMap[task.taskIdentifier] else { fatalError() }
        let loadingRequest = requestData.loadingRequest
        let receivedBytes = requestData.dataCount
        if let urlError = error as? URLError, urlError.errorCode == NSURLErrorCancelled {
            LogManager.service()
                .debug("error=\(String(describing: error)), received \(receivedBytes) bytes", tag: "StreamUrlSessionDataDelegate")
        } else if error != nil {
            LogManager.service()
                .debug("error=\(String(describing: error)), received \(receivedBytes) bytes", tag: "StreamUrlSessionDataDelegate")
        } else {
            LogManager.service().debug("complete, received \(receivedBytes) bytes", tag: "StreamUrlSessionDataDelegate")
        }

        LogManager.service().debug("utType: \(String(describing: requestData.utType?.identifier))", tag: "StreamUrlSessionDataDelegate")

        if !loadingRequest.isFinished {
            if let error = error {
                loadingRequest.finishLoading(with: error)
                guard (error as? URLError)?.errorCode == NSURLErrorCancelled else {
                    fatalError()
                }
            } else {
                loadingRequest.finishLoading()
            }
        }

        self.taskRequestMap.removeValue(forKey: task.taskIdentifier)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let requestData = taskRequestMap[dataTask.taskIdentifier] else { fatalError() }
        let loadingRequest = requestData.loadingRequest
        guard let httpResponse = response as? HTTPURLResponse, (200 ... 299).contains(httpResponse.statusCode) else {
            if let httpResponse = response as? HTTPURLResponse {
                LogManager.service().debug("bad status=\(httpResponse.statusCode)", tag: "StreamUrlSessionDataDelegate")
            } else {
                LogManager.service().debug("bad response", tag: "StreamUrlSessionDataDelegate")
            }
            loadingRequest.finishLoading(with: TlsLoaderError.runtimeError("bad status/response"))
            completionHandler(.cancel)
            return
        }

        guard let mimeType = httpResponse.mimeType else {
            LogManager.service().debug("no mime type", tag: "StreamUrlSessionDataDelegate")
            loadingRequest.finishLoading(with: TlsLoaderError.runtimeError("no mime type"))
            completionHandler(.cancel)
            return
        }

        requestData.utType = UTType(mimeType: mimeType)
        if let cir = loadingRequest.contentInformationRequest {
            if cir.allowedContentTypes != nil {
                fatalError()
            }
            cir.contentType = requestData.utType?.identifier
            LogManager.service().debug("httpResponse.statusCode=\(httpResponse.statusCode)", tag: "StreamUrlSessionDataDelegate")
            if let acceptRanges = httpResponse.value(forHTTPHeaderField: "Accept-Ranges"), acceptRanges == "bytes" {
                cir.isByteRangeAccessSupported = true
            } else {
                cir.isByteRangeAccessSupported = false
            }
            LogManager.service().debug("isByteRangeAccessSupported=\(cir.isByteRangeAccessSupported)", tag: "StreamUrlSessionDataDelegate")
            if let contentRangeHeaderValue = httpResponse.value(forHTTPHeaderField: "Content-Range") {
                if let parsedRangeTotal = StreamResourceLoaderDelegate.parseContentRange(header: contentRangeHeaderValue) {
                    cir.contentLength = parsedRangeTotal
                    LogManager.service().debug("contentLength=\(cir.contentLength)", tag: "StreamUrlSessionDataDelegate")
                }
            }
            LogManager.service().debug("headers=\(httpResponse.allHeaderFields)", tag: "StreamUrlSessionDataDelegate")
        } else {
            LogManager.service().debug("data request", tag: "TlsResourceLoader:resourceLoader")
        }

        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        fatalError()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if self.authDelegate?.urlSession?(session, didReceive: challenge, completionHandler: completionHandler) != nil {
            LogManager.service().debug("handled auth challenge", tag: "StreamUrlSessionDataDelegate")
        } else {
            LogManager.service().debug("default auth challenge handling", tag: "StreamUrlSessionDataDelegate")
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        LogManager.service().debug("(\(task.taskIdentifier)) didCreateTask", tag: "StreamUrlSessionDataDelegate")
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didBecome downloadTask: URLSessionDownloadTask) {
        fatalError()
    }

//    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
//        fatalError()
//    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        fatalError()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willBeginDelayedRequest request: URLRequest,
        completionHandler: @escaping (URLSession.DelayedRequestDisposition, URLRequest?) -> Void
    ) {
        fatalError()
    }
}

class StreamResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    var delegate: StreamUrlSessionDataDelegate
    let urlSession: URLSession

    var requestMap: [AVAssetResourceLoadingRequest: URLSessionDataTask] = [:]

    init(authDelegate: URLSessionDelegate? = nil) {
        self.delegate = StreamUrlSessionDataDelegate(authDelegate: authDelegate)
        self.urlSession = URLSession(configuration: .default, delegate: self.delegate, delegateQueue: nil)
    }

    static let customSchemePrefix = "ctls"

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForResponseTo authenticationChallenge: URLAuthenticationChallenge
    ) -> Bool {
        LogManager.service().debug(
            "rl challenge.protectionSpace.authenticationMethod=\(authenticationChallenge.protectionSpace.authenticationMethod)",
            tag: "TlsResourceLoader:resourceLoader"
        )

        return false
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel authenticationChallenge: URLAuthenticationChallenge) {
        LogManager.service().debug("cancelled authChallenge", tag: "TlsResourceLoader:resourceLoader")
        fatalError()
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let isContentInformationRequest = loadingRequest.contentInformationRequest != nil
        LogManager.service()
            .debug("shouldWaitForLoadingOfRequestedResource, isCIR=\(isContentInformationRequest)", tag: "TlsResourceLoader:resourceLoader")
        guard let dataRequest = loadingRequest.dataRequest else {
            LogManager.service().debug("bad dataRequest", tag: "TlsResourceLoader:resourceLoader")
            return false
        }

        guard var urlToLoad = loadingRequest.request.url else { return false }
        urlToLoad = StreamResourceLoaderDelegate.transformUrlScheme(url: urlToLoad)

        let lower = dataRequest.requestedOffset
        let upper = Int(lower) + dataRequest.requestedLength - 1
        let rangeHeader = "bytes=\(lower)-\(upper)"
        LogManager.service().debug("rangeHeader=\(rangeHeader)", tag: "TlsResourceLoader:resourceLoader")

        var urlRequest = URLRequest(url: urlToLoad)
        urlRequest.setValue(rangeHeader, forHTTPHeaderField: "Range")

        let task = urlSession.dataTask(with: urlRequest)
        requestMap[loadingRequest] = task
        delegate.taskRequestMap[task.taskIdentifier] = RequestData(loadingRequest: loadingRequest)
        task.resume()

        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        guard let task = requestMap.removeValue(forKey: loadingRequest) else { fatalError("Missing task, possible leak") }
        task.cancel()
        LogManager.service()
            .debug(
                "cancelled loadingRequest=\(loadingRequest), requestMap.count=\(requestMap.count)",
                tag: "TlsResourceLoader:resourceLoader"
            )
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForRenewalOfRequestedResource renewalRequest: AVAssetResourceRenewalRequest
    ) -> Bool {
        fatalError()
    }

    // Our AVAssetResourceLoaderDelegate is only called for schemes that AVPlayer doesn't know how to handle
    static func transformUrlScheme(url: URL) -> URL {
        let _components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        guard var components = _components else { return url }
        guard let scheme = components.scheme else { return url }

        if scheme.starts(with: customSchemePrefix) {
            components.scheme = String(scheme.dropFirst(customSchemePrefix.count))
        } else {
            components.scheme = "\(customSchemePrefix)\(scheme)"
        }

        return components.url ?? url
    }

    // We only care about the total bytes
    static func parseContentRange(header: String) -> Int64? {
        guard header.starts(with: "bytes ") else { return nil }
        guard let slashIndex = header.firstIndex(of: "/") else { return nil }
        let totalStr = header[header.index(slashIndex, offsetBy: 1)...]
        guard let total = Int64(totalStr) else { return nil }
        return total
    }
}
