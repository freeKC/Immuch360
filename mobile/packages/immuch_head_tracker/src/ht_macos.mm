// The webcams of macOS for the head tracker: AVFoundation, on a capture thread of the library.
//
// - The cameras of AVCaptureDeviceDiscoverySession (built-in and external, Continuity Camera included, desk view left
//   out); the built-in one is "front".
// - Permission: the app's Info.plist carries NSCameraUsageDescription (without it macOS ends the app at the first
//   camera open). An answer not given yet asks the system (requestAccessForMediaType) on the capture thread, so that
//   the prompt never blocks the page; a refusal or a restriction gives HT_E_ACCESS_DENIED, for the message with the
//   button that opens Privacy and Security, Camera.
// - The session asks for 640 x 480, the frame duration locked to 1 / 30 s when the format allows it, and the frames as
//   420 bi-planar: the luma plane is read in place on the delegate queue, the buffer goes back at once, nothing is
//   copied out or written anywhere. Late frames are dropped, never queued.
// - Center Stage (macOS 12.3 and later), which would keep the face in the middle and flatten the parallax: the app
//   takes its control (centerStageControlMode = app) and turns it off while tracking, then gives it back as it was.
//   HtInfo.framing says what was found, as for Windows Studio Effects.
// - "file:<path>": a video file read by AVAssetReader at its own pace through the same path, for the Mac runner's
//   tests (it has no webcam), and ht_open_file for the frame by frame reader.

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

#include <string>

#include "ht_tracker.h"

// ht::ThreadState is always written in full here: the macOS SDK has a ThreadState of its own (MacTypes)
using ht::LumaPlane;

@interface HtFrameDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
- (instancetype)initWithState:(std::shared_ptr<ht::ThreadState>)state;
@end

@implementation HtFrameDelegate {
  std::shared_ptr<ht::ThreadState> _state;
}

- (instancetype)initWithState:(std::shared_ptr<ht::ThreadState>)state {
  self = [super init];
  if (self != nil) {
    _state = state;
  }
  return self;
}

- (void)captureOutput:(AVCaptureOutput*)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection*)connection {
  if (_state->stop) {
    return;
  }
  CVImageBufferRef image = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (image == nullptr) {
    return;
  }
  CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
  LumaPlane plane;
  plane.data = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(image, 0));
  plane.width = static_cast<int32_t>(CVPixelBufferGetWidthOfPlane(image, 0));
  plane.height = static_cast<int32_t>(CVPixelBufferGetHeightOfPlane(image, 0));
  plane.stride = static_cast<ptrdiff_t>(CVPixelBufferGetBytesPerRowOfPlane(image, 0));
  if (plane.data != nullptr && plane.width >= 16 && plane.height >= 16) {
    _state->Frame(plane, ht::NowUs());
  }
  CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
}

@end

namespace ht {

namespace {

NSArray<AVCaptureDevice*>* Cameras() {
  NSMutableArray<AVCaptureDeviceType>* types = [NSMutableArray arrayWithObject:AVCaptureDeviceTypeBuiltInWideAngleCamera];
  if (@available(macOS 14.0, *)) {
    [types addObject:AVCaptureDeviceTypeExternal];
    [types addObject:AVCaptureDeviceTypeContinuityCamera];
  } else {
    [types addObject:AVCaptureDeviceTypeExternalUnknown];
  }
  AVCaptureDeviceDiscoverySession* discovery =
      [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types
                                                             mediaType:AVMediaTypeVideo
                                                              position:AVCaptureDevicePositionUnspecified];
  return discovery.devices;
}

void AppendJsonString(std::string* json, NSString* text) {
  const char* utf8 = text.UTF8String ?: "";
  json->push_back('"');
  for (const char* c = utf8; *c != '\0'; c++) {
    const unsigned char u = static_cast<unsigned char>(*c);
    if (*c == '"' || *c == '\\') {
      json->push_back('\\');
      json->push_back(*c);
    } else if (u < 0x20) {
      char escaped[8];
      snprintf(escaped, sizeof(escaped), "\\u%04x", u);
      json->append(escaped);
    } else {
      json->push_back(*c);
    }
  }
  json->push_back('"');
}

// HT_OK when the app may use the camera, asking the system the first time (blocks this thread until the answer)
int32_t Authorise() {
  switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]) {
    case AVAuthorizationStatusAuthorized:
      return HT_OK;
    case AVAuthorizationStatusDenied:
    case AVAuthorizationStatusRestricted:
      return HT_E_ACCESS_DENIED;
    case AVAuthorizationStatusNotDetermined:
    default: {
      dispatch_semaphore_t answered = dispatch_semaphore_create(0);
      __block BOOL allowed = NO;
      [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                               completionHandler:^(BOOL granted) {
                                 allowed = granted;
                                 dispatch_semaphore_signal(answered);
                               }];
      dispatch_semaphore_wait(answered, DISPATCH_TIME_FOREVER);
      return allowed ? HT_OK : HT_E_ACCESS_DENIED;
    }
  }
}

// The format of [device] closest to the size asked for, among those that can run at the frame rate asked for
AVCaptureDeviceFormat* ClosestFormat(AVCaptureDevice* device, const HtOptions& options) {
  AVCaptureDeviceFormat* best = nil;
  double best_score = 0;
  const double wanted = static_cast<double>(options.width) * options.height;
  for (AVCaptureDeviceFormat* format in device.formats) {
    const CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
    const double area = static_cast<double>(size.width) * size.height;
    if (area <= 0) {
      continue;
    }
    double max_rate = 0;
    for (AVFrameRateRange* range in format.videoSupportedFrameRateRanges) {
      max_rate = MAX(max_rate, range.maxFrameRate);
    }
    double score = area >= wanted ? area / wanted - 1 : (wanted / area - 1) * 2;
    score += max_rate >= options.fps ? 0 : (options.fps - max_rate) / options.fps * 2;
    if (best == nil || score < best_score) {
      best = format;
      best_score = score;
    }
  }
  return best;
}

void Publish(const std::shared_ptr<ht::ThreadState>& state, int32_t width, int32_t height, double fps, uint32_t fourcc,
             int32_t framing) {
  std::lock_guard<std::mutex> lock(state->shared->mutex);
  state->shared->info.width = width;
  state->shared->info.height = height;
  state->shared->info.fps_numerator = static_cast<int32_t>(fps * 1000);
  state->shared->info.fps_denominator = fps > 0 ? 1000 : 0;
  state->shared->info.native_fourcc = fourcc;
  state->shared->info.framing = framing;
}

void RunCamera(std::shared_ptr<ht::ThreadState> state) {
  @autoreleasepool {
    const int32_t authorised = Authorise();
    if (authorised != HT_OK) {
      state->Fail(authorised);
      return;
    }
    if (state->stop) {
      return;
    }
    AVCaptureDevice* device = [AVCaptureDevice deviceWithUniqueID:[NSString stringWithUTF8String:state->id.c_str()]];
    if (device == nil) {
      state->Fail(HT_E_NO_CAMERA);
      return;
    }
    NSError* error = nil;
    AVCaptureDeviceInput* input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (input == nil) {
      // Refused by the system, or held by another app
      const bool allowed =
          [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] == AVAuthorizationStatusAuthorized;
      state->Fail(allowed ? HT_E_CAMERA_BUSY : HT_E_ACCESS_DENIED);
      return;
    }
    AVCaptureSession* session = [[AVCaptureSession alloc] init];
    [session beginConfiguration];
    if (![session canAddInput:input]) {
      [session commitConfiguration];
      state->Fail(HT_E_CAMERA_BUSY);
      return;
    }
    [session addInput:input];
    AVCaptureVideoDataOutput* output = [[AVCaptureVideoDataOutput alloc] init];
    output.alwaysDiscardsLateVideoFrames = YES;
    output.videoSettings = @{
      (NSString*)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
    };
    HtFrameDelegate* delegate = [[HtFrameDelegate alloc] initWithState:state];
    dispatch_queue_t queue = dispatch_queue_create("immuch360.head-tracker", DISPATCH_QUEUE_SERIAL);
    [output setSampleBufferDelegate:delegate queue:queue];
    if (![session canAddOutput:output]) {
      [session commitConfiguration];
      state->Fail(HT_E_FORMAT);
      return;
    }
    [session addOutput:output];
    [session commitConfiguration];

    // The format and the frame rate, and Center Stage off, under the device's lock
    int32_t framing = HT_FRAMING_ABSENT;
    BOOL center_stage_was_on = NO;
    AVCaptureCenterStageControlMode center_stage_mode = AVCaptureCenterStageControlModeUser;
    double fps = 0;
    if ([device lockForConfiguration:&error]) {
      AVCaptureDeviceFormat* format = ClosestFormat(device, state->options);
      if (format != nil) {
        device.activeFormat = format;
      }
      const CMTime duration = CMTimeMake(1, state->options.fps);
      for (AVFrameRateRange* range in device.activeFormat.videoSupportedFrameRateRanges) {
        if (range.minFrameRate <= state->options.fps && state->options.fps <= range.maxFrameRate) {
          device.activeVideoMinFrameDuration = duration;
          device.activeVideoMaxFrameDuration = duration;
          break;
        }
      }
      [device unlockForConfiguration];
    }
    if (@available(macOS 12.3, *)) {
      if (device.activeFormat.centerStageSupported) {
        center_stage_mode = AVCaptureDevice.centerStageControlMode;
        center_stage_was_on = AVCaptureDevice.centerStageEnabled;
        if (center_stage_was_on) {
          AVCaptureDevice.centerStageControlMode = AVCaptureCenterStageControlModeApp;
          AVCaptureDevice.centerStageEnabled = NO;
          framing = AVCaptureDevice.centerStageEnabled ? HT_FRAMING_STUCK_ON : HT_FRAMING_TURNED_OFF;
        } else {
          framing = HT_FRAMING_OFF;
        }
      }
    }
    const CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription);
    if (CMTIME_IS_VALID(device.activeVideoMinFrameDuration) && device.activeVideoMinFrameDuration.value > 0) {
      fps = static_cast<double>(device.activeVideoMinFrameDuration.timescale) / device.activeVideoMinFrameDuration.value;
    }
    Publish(state, size.width, size.height, fps,
            CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription), framing);

    // Unplugged, or taken by another app with priority
    __block int32_t failure = HT_OK;
    id runtime = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVCaptureSessionRuntimeErrorNotification
                    object:session
                     queue:nil
                usingBlock:^(NSNotification* note) {
                  failure = HT_E_DEVICE_LOST;
                  std::lock_guard<std::mutex> lock(state->stop_mutex);
                  state->stop_signal.notify_all();
                }];
    id disconnected = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVCaptureDeviceWasDisconnectedNotification
                    object:device
                     queue:nil
                usingBlock:^(NSNotification* note) {
                  failure = HT_E_DEVICE_LOST;
                  std::lock_guard<std::mutex> lock(state->stop_mutex);
                  state->stop_signal.notify_all();
                }];
    [session startRunning];
    if (!session.running) {
      failure = HT_E_CAMERA_BUSY;
    }
    while (failure == HT_OK && !state->WaitStop(std::chrono::milliseconds(200))) {
    }
    [output setSampleBufferDelegate:nil queue:nil];
    [session stopRunning];
    // The delegate's last frame done before the session goes
    dispatch_sync(queue, ^{
                  });
    [[NSNotificationCenter defaultCenter] removeObserver:runtime];
    [[NSNotificationCenter defaultCenter] removeObserver:disconnected];
    if (@available(macOS 12.3, *)) {
      if (center_stage_was_on) {
        AVCaptureDevice.centerStageEnabled = YES;
        AVCaptureDevice.centerStageControlMode = center_stage_mode;
      }
    }
    if (failure != HT_OK && !state->stop) {
      state->Fail(failure);
    }
  }
}

// A video file read by AVAssetReader as 420 bi-planar frames
class AssetFrames {
 public:
  int32_t Open(const std::string& path) {
    NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:url options:nil];
    NSError* error = nil;
    reader_ = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (reader_ == nil) {
      return HT_E_ARGUMENT;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray<AVAssetTrack*>* tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
#pragma clang diagnostic pop
    if (tracks.count == 0) {
      return HT_E_FORMAT;
    }
    output_ = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:tracks[0]
                         outputSettings:@{
                           (NSString*)kCVPixelBufferPixelFormatTypeKey :
                               @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                         }];
    if (![reader_ canAddOutput:output_]) {
      return HT_E_FORMAT;
    }
    [reader_ addOutput:output_];
    if (![reader_ startReading]) {
      return HT_E_FORMAT;
    }
    return HT_OK;
  }

  // The next frame's luma to [frame] with its time in microseconds; false at the end
  template <typename Frame>
  bool Next(Frame frame) {
    @autoreleasepool {
      CMSampleBufferRef sample = [output_ copyNextSampleBuffer];
      if (sample == nullptr) {
        return false;
      }
      const CMTime time = CMSampleBufferGetPresentationTimeStamp(sample);
      const int64_t time_us = CMTIME_IS_VALID(time) ? static_cast<int64_t>(CMTimeGetSeconds(time) * 1e6) : 0;
      CVImageBufferRef image = CMSampleBufferGetImageBuffer(sample);
      if (image != nullptr) {
        CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
        LumaPlane plane;
        plane.data = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(image, 0));
        plane.width = static_cast<int32_t>(CVPixelBufferGetWidthOfPlane(image, 0));
        plane.height = static_cast<int32_t>(CVPixelBufferGetHeightOfPlane(image, 0));
        plane.stride = static_cast<ptrdiff_t>(CVPixelBufferGetBytesPerRowOfPlane(image, 0));
        if (plane.data != nullptr && plane.width >= 16 && plane.height >= 16) {
          frame(plane, time_us);
        }
        CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
      }
      CFRelease(sample);
      return true;
    }
  }

 private:
  AVAssetReader* reader_ = nil;
  AVAssetReaderTrackOutput* output_ = nil;
};

void RunFile(std::shared_ptr<ht::ThreadState> state, std::string path) {
  @autoreleasepool {
    AssetFrames frames;
    const int32_t opened = frames.Open(path);
    if (opened != HT_OK) {
      state->Fail(opened == HT_E_ARGUMENT ? HT_E_NO_CAMERA : opened);
      return;
    }
    const int64_t start = NowUs();
    bool more = true;
    while (more && !state->stop) {
      more = frames.Next([&state, start](const LumaPlane& plane, int64_t time_us) {
        const int64_t wait = start + time_us - NowUs();
        if (wait > 0 && state->WaitStop(std::chrono::microseconds(wait))) {
          return;
        }
        state->Frame(plane, NowUs());
      });
    }
    if (!state->stop) {
      state->Fail(HT_E_DEVICE_LOST);
    }
  }
}

// ht_open_file: one analysed frame per Next
class FileSource : public Source {
 public:
  explicit FileSource(std::unique_ptr<AssetFrames> frames) : frames_(std::move(frames)) {}

  int32_t Next(Tracker* tracker, HtSample* sample) override {
    while (true) {
      bool analysed = false;
      const bool more = frames_->Next([&](const LumaPlane& plane, int64_t time_us) {
        if (!tracker->core->CountFrame()) {
          return;
        }
        tracker->core->Analyse(plane, time_us, sample);
        std::lock_guard<std::mutex> lock(tracker->shared->mutex);
        tracker->shared->latest = *sample;
        tracker->shared->has_latest = true;
        tracker->shared->info.width = plane.width;
        tracker->shared->info.height = plane.height;
        analysed = true;
      });
      if (!more) {
        return 0;
      }
      if (analysed) {
        return 1;
      }
    }
  }

  void Stop() override {}

 private:
  std::unique_ptr<AssetFrames> frames_;
};

}  // namespace

int32_t ListCameras(std::string* json) {
  @autoreleasepool {
    json->assign("[");
    bool first = true;
    for (AVCaptureDevice* device in Cameras()) {
      if (!first) {
        json->push_back(',');
      }
      first = false;
      json->append("{\"id\":");
      AppendJsonString(json, device.uniqueID);
      json->append(",\"name\":");
      AppendJsonString(json, device.localizedName);
      json->append(",\"panel\":");
      json->append([device.deviceType isEqualToString:AVCaptureDeviceTypeBuiltInWideAngleCamera] ? "\"front\""
                                                                                                 : "\"unknown\"");
      json->append(",\"virtual\":false,\"grey\":false}");
    }
    json->push_back(']');
    return HT_OK;
  }
}

int32_t OpenCamera(Tracker* tracker, const std::string& id, std::unique_ptr<Source>* source) {
  if (id.empty()) {
    return HT_E_ARGUMENT;
  }
  auto state = NewThreadState(tracker, id);
  if (id.compare(0, 5, "file:") == 0) {
    const std::string path = id.substr(5);
    *source = std::make_unique<ThreadSource>(state, [path](std::shared_ptr<ht::ThreadState> s) { RunFile(s, path); });
  } else {
    *source = std::make_unique<ThreadSource>(state, [](std::shared_ptr<ht::ThreadState> s) { RunCamera(s); });
  }
  return HT_OK;
}

int32_t OpenFile(Tracker* tracker, const std::string& path, std::unique_ptr<Source>* source) {
  auto frames = std::make_unique<AssetFrames>();
  const int32_t opened = frames->Open(path);
  if (opened != HT_OK) {
    return opened;
  }
  (void)tracker;
  *source = std::make_unique<FileSource>(std::move(frames));
  return HT_OK;
}

}  // namespace ht
