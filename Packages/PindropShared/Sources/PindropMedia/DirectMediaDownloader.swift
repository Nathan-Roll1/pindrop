//
//  DirectMediaDownloader.swift
//  PindropMedia
//
//  Created on 2026-07-22.
//

import Foundation

/// URLSession download delegate that preserves immediate success/failure results
/// and moves the temporary download file before URLSession deletes it.
public final class DirectDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private let onProgress: (Int64, Int64) -> Void
    private let temporaryDirectory: URL

    public init(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        onProgress: @escaping (Int64, Int64) -> Void
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.onProgress = onProgress
    }

    /// Installs the continuation before starting the task so an immediately
    /// completing URLSession task cannot lose its result.
    public func waitForCompletion(start: () -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let pendingResult = lock.withLock { () -> Result<URL, Error>? in
                if let result {
                    return result
                }
                self.continuation = continuation
                return nil
            }

            if let pendingResult {
                continuation.resume(with: pendingResult)
            } else {
                start()
            }
        }
    }

    public func cancel() {
        complete(.failure(CancellationError()))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // URLSession deletes the temp file when this method returns, so move it first.
        let safeURL = temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(location.pathExtension)
        do {
            try FileManager.default.moveItem(at: location, to: safeURL)
            if !complete(.success(safeURL)) {
                try? FileManager.default.removeItem(at: safeURL)
            }
        } catch {
            complete(.failure(error))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        complete(.failure(error))
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    @discardableResult
    private func complete(_ result: Result<URL, Error>) -> Bool {
        let (continuation, didComplete) = lock.withLock { () -> (CheckedContinuation<URL, Error>?, Bool) in
            guard self.result == nil else { return (nil, false) }
            self.result = result
            defer { self.continuation = nil }
            return (self.continuation, true)
        }
        continuation?.resume(with: result)
        return didComplete
    }
}

/// Direct HTTP media download path using URLSession (no external process tooling).
///
/// Construction is side-effect free: no network work runs until `download` is called.
public final class DirectMediaDownloader: @unchecked Sendable {
    private let mediaLibrary: any MediaLibraryManaging
    private let fileManager: FileManager
    private let sessionConfiguration: URLSessionConfiguration

    public init(
        mediaLibrary: any MediaLibraryManaging,
        fileManager: FileManager = .default,
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.mediaLibrary = mediaLibrary
        self.fileManager = fileManager
        self.sessionConfiguration = sessionConfiguration
    }

    /// Downloads media over HTTP(S) into a job directory and finalizes a managed asset.
    public func download(
        from url: URL,
        jobID: UUID,
        progressHandler: @escaping @Sendable (Double?, String) -> Void
    ) async throws -> ManagedMediaAsset {
        let directoryURL = try mediaLibrary.makeJobDirectory(for: jobID)
        return try await download(from: url, to: directoryURL, progressHandler: progressHandler)
    }

    /// Downloads media over HTTP(S) into an existing job directory and finalizes a managed asset.
    public func download(
        from url: URL,
        to directoryURL: URL,
        progressHandler: @escaping @Sendable (Double?, String) -> Void
    ) async throws -> ManagedMediaAsset {
        progressHandler(nil, "Connecting…")

        let ext = url.pathExtension.lowercased()
        let destURL = directoryURL.appendingPathComponent("media.\(ext)")

        let delegate = DirectDownloadDelegate { written, total in
            let progress: Double? = total > 0 ? Double(written) / Double(total) : nil
            let byteStr = ByteCountFormatter.string(fromByteCount: written, countStyle: .file)
            progressHandler(progress, "Downloading \(byteStr)…")
        }
        let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        let downloadTask = session.downloadTask(with: url)
        defer { session.invalidateAndCancel() }

        let tempURL = try await withTaskCancellationHandler {
            try await delegate.waitForCompletion {
                downloadTask.resume()
            }
        } onCancel: {
            downloadTask.cancel()
            delegate.cancel()
        }
        var ownsTempURL = true
        defer {
            if ownsTempURL {
                try? fileManager.removeItem(at: tempURL)
            }
        }
        try Task.checkCancellation()

        guard let httpResponse = downloadTask.response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
            throw MediaLibraryError.downloadFailed("Server returned HTTP \(status).")
        }

        if fileManager.fileExists(atPath: destURL.path) {
            try fileManager.removeItem(at: destURL)
        }
        try fileManager.moveItem(at: tempURL, to: destURL)
        ownsTempURL = false

        // Reuse the library's finalization path, which generates a thumbnail
        // and builds the ManagedMediaAsset from whatever is in the directory.
        return try await mediaLibrary.finalizeDownloadedAsset(
            in: directoryURL,
            sourceURL: url.absoluteString,
            suggestedTitle: url.deletingPathExtension().lastPathComponent
        )
    }
}
