import AVFoundation
import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers

/// Host side of the PhoneShareApi pigeon, for "Share this phone on the network" on iOS.
///
/// The share runs while the app is in front only (no background mode), so the keep-alive is the screen kept awake,
/// set again every few seconds while the share runs.
/// The files: the size, type, name and date of the assets without reading them (PhotoKit, for the listings), then a
/// path Dart can read each one from. A video is read in place when PhotoKit gives its file and the app may read it;
/// anything else is written once to the temporary folder, deleted when the share stops. Assets in iCloud only are
/// left out: the share never downloads.
class PhoneShareApiImpl: PhoneShareApi {
  private static let folderName = "phone_share"
  /// How often the screen is set awake again while the share runs
  private static let keepAwakeInterval: TimeInterval = 2
  private let queue = DispatchQueue(label: "app.alextran.immich.phoneshare", qos: .userInitiated, attributes: .concurrent)
  /// Main thread only
  private var keepAwakeTimer: Timer?

  func startKeepAlive(title: String, text: String, stopLabel: String) throws {
    Self.onMain {
      UIApplication.shared.isIdleTimerDisabled = true
      // The pages that keep the screen awake for themselves (videos, slideshow, backup) turn the same flag off when
      // they are done: set again on the main run loop, so that the phone does not lock and pause the share
      self.keepAwakeTimer?.invalidate()
      self.keepAwakeTimer = Timer.scheduledTimer(withTimeInterval: Self.keepAwakeInterval, repeats: true) { _ in
        if !UIApplication.shared.isIdleTimerDisabled {
          UIApplication.shared.isIdleTimerDisabled = true
        }
      }
    }
  }

  func updateKeepAlive(text: String) throws {
    // No notification on iOS
  }

  func stopKeepAlive() throws {
    Self.onMain {
      self.keepAwakeTimer?.invalidate()
      self.keepAwakeTimer = nil
      UIApplication.shared.isIdleTimerDisabled = false
    }
  }

  func fileInfos(assetIds: [String], completion: @escaping (Result<[PhoneShareFileInfo], Error>) -> Void) {
    queue.async {
      var infos: [PhoneShareFileInfo] = []
      let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIds, options: nil)
      assets.enumerateObjects { asset, _, _ in
        guard let resource = Self.resource(of: asset), Self.isLocallyAvailable(resource) else { return }
        let date = asset.modificationDate ?? asset.creationDate ?? Date(timeIntervalSince1970: 0)
        infos.append(
          PhoneShareFileInfo(
            assetId: asset.localIdentifier,
            size: Self.fileSize(of: resource),
            mimeType: Self.mimeType(of: resource),
            fileName: resource.originalFilename,
            modifiedMs: Int64(date.timeIntervalSince1970 * 1000)
          ))
      }
      let found = infos
      Self.onMain { completion(.success(found)) }
    }
  }

  func openFile(assetId: String, completion: @escaping (Result<PhoneShareOpenedFile?, Error>) -> Void) {
    let finish: (Result<PhoneShareOpenedFile?, Error>) -> Void = { result in Self.onMain { completion(result) } }
    queue.async {
      guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject,
        let resource = Self.resource(of: asset)
      else {
        return finish(.success(nil))
      }
      guard asset.mediaType == .video else {
        return Self.copy(resource, of: asset, completion: finish)
      }
      let options = PHVideoRequestOptions()
      options.version = .current
      options.isNetworkAccessAllowed = false
      options.deliveryMode = .highQualityFormat
      PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
        // The video in place when it is a plain file the app may read; a slow motion edit is a composition instead
        if let urlAsset = avAsset as? AVURLAsset, urlAsset.url.isFileURL,
          FileManager.default.isReadableFile(atPath: urlAsset.url.path),
          let size = Self.sizeOfFile(atPath: urlAsset.url.path)
        {
          return finish(.success(PhoneShareOpenedFile(path: urlAsset.url.path, size: size, isTemporary: false)))
        }
        Self.copy(resource, of: asset, completion: finish)
      }
    }
  }

  func releaseTemporaryFiles() throws {
    let folder = Self.temporaryFolder()
    queue.async(flags: .barrier) {
      try? FileManager.default.removeItem(at: folder)
    }
  }

  /// The resource the share serves: the rendered edit when the asset was edited, else the original; the still of a
  /// live photo
  private static func resource(of asset: PHAsset) -> PHAssetResource? {
    let types: [PHAssetResourceType]
    switch asset.mediaType {
    case .image: types = [.fullSizePhoto, .photo]
    case .video: types = [.fullSizeVideo, .video]
    default: return nil
    }
    let resources = PHAssetResource.assetResources(for: asset)
    for type in types {
      if let resource = resources.first(where: { $0.type == type }) {
        return resource
      }
    }
    return nil
  }

  /// Whether the resource is on the device (undocumented key, the one photo_manager reads too); true when the key is
  /// not there, so that a change of iOS does not hide every asset. Key-value coding finds the property through its
  /// getter, plain or "is" prefixed, and raises an Objective-C exception Swift cannot catch when there is neither:
  /// hence the check of both selectors first.
  private static func isLocallyAvailable(_ resource: PHAssetResource) -> Bool {
    guard
      resource.responds(to: NSSelectorFromString("locallyAvailable"))
        || resource.responds(to: NSSelectorFromString("isLocallyAvailable"))
    else { return true }
    return (resource.value(forKey: "locallyAvailable") as? NSNumber)?.boolValue ?? true
  }

  /// The size of the resource (undocumented key), for the listings only; 0 when iOS does not tell, the client then
  /// learns the size from the first read
  private static func fileSize(of resource: PHAssetResource) -> Int64 {
    guard resource.responds(to: NSSelectorFromString("fileSize")) else { return 0 }
    return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
  }

  private static func mimeType(of resource: PHAssetResource) -> String {
    UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? "application/octet-stream"
  }

  /// Writes [resource] once to the temporary folder; PhotoKit refuses to write over a file, so a copy made by an
  /// earlier read is used again, and a new one is written beside then moved in place
  private static func copy(
    _ resource: PHAssetResource, of asset: PHAsset,
    completion: @escaping (Result<PhoneShareOpenedFile?, Error>) -> Void
  ) {
    let manager = FileManager.default
    let folder = temporaryFolder()
    do {
      try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    } catch {
      return completion(.failure(error))
    }
    let pathExtension = (resource.originalFilename as NSString).pathExtension
    let name = safeName(asset.localIdentifier) + (pathExtension.isEmpty ? "" : ".\(pathExtension)")
    let target = folder.appendingPathComponent(name)
    if let size = sizeOfFile(atPath: target.path), size > 0 {
      return completion(.success(PhoneShareOpenedFile(path: target.path, size: size, isTemporary: true)))
    }
    let partial = folder.appendingPathComponent("\(name).\(UUID().uuidString).part")
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = false
    PHAssetResourceManager.default().writeData(for: resource, toFile: partial, options: options) { error in
      if let error = error {
        try? manager.removeItem(at: partial)
        return completion(.failure(error))
      }
      do {
        try manager.moveItem(at: partial, to: target)
      } catch {
        // Another read wrote it meanwhile: that copy is as good
        try? manager.removeItem(at: partial)
        guard manager.fileExists(atPath: target.path) else { return completion(.failure(error)) }
      }
      guard let size = Self.sizeOfFile(atPath: target.path) else {
        return completion(.success(nil))
      }
      completion(.success(PhoneShareOpenedFile(path: target.path, size: size, isTemporary: true)))
    }
  }

  private static func temporaryFolder() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(folderName, isDirectory: true)
  }

  /// A local identifier ("ABC-123/L0/001") as a file name
  private static func safeName(_ identifier: String) -> String {
    String(identifier.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
  }

  private static func sizeOfFile(atPath path: String) -> Int64? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let size = attributes[.size] as? NSNumber
    else { return nil }
    return size.int64Value
  }

  private static func onMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
      block()
    } else {
      DispatchQueue.main.async(execute: block)
    }
  }
}
