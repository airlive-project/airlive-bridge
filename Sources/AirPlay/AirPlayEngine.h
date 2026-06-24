#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Standalone, OBS-free, video-only AirPlay (Screen Mirroring) receiver.
///
/// Advertises an Apple-TV-style RAOP/AirPlay service over Bonjour so an iPhone
/// shows it in Control Center → Screen Mirroring. Incoming H.264 mirror frames
/// are decoded on a dedicated thread via VideoToolbox and delivered through
/// `onVideoFrame`. Audio is intentionally discarded.
///
/// Plain ObjC interface (no C++ in the header) so it can be used directly from
/// Swift via a bridging header.
@interface AirPlayEngine : NSObject

- (instancetype)initWithName:(NSString *)name;

/// Called on a background (decoder) thread for every decoded frame.
/// The pixel buffer is owned by the engine and valid only for the duration of
/// the block — retain it if you need it past the call.
@property (nonatomic, copy, nullable) void (^onVideoFrame)(CVPixelBufferRef pixelBuffer, uint64_t ptsNs);

- (void)start;
- (void)stop;

/// Restart the AirPlay server advertised as this Apple-TV name.
- (void)setAdvertiseName:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
