#pragma once
//
// VideoToolbox-based H.264 decoder. macOS only.
//
// Apple's hardware decoder, going straight from compressed H.264 to a
// CVPixelBuffer (NV12 / 420v) without any RGBA detour. Saves CPU and memcpy
// bandwidth on Apple Silicon vs. a software ffmpeg+sws_scale path.
//
// Input format: Annex B (4-byte start codes), as produced by UxPlay's
// raop_rtp_mirror.c — we convert to avcC (length-prefixed) internally
// before feeding VideoToolbox.
//
// Ownership: decode() returns a RETAINED CVPixelBufferRef that the CALLER
// owns and must CVPixelBufferRelease after use, or nullptr if no frame is
// ready (e.g. first packets carry only SPS/PPS, or a decode error). This is
// the OBS-free port: there is no internal "current buffer" the caller borrows
// — every successful decode hands back an owning reference.

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <cstdint>
#include <mutex>
#include <span>
#include <vector>

class H264DecoderVT
{
public:
  H264DecoderVT();
  ~H264DecoderVT();

  // Decode one Annex-B access unit (+ pts in the caller's clock domain).
  // Returns a RETAINED CVPixelBufferRef on success (caller releases), or
  // nullptr if no frame is ready or on error. SPS/PPS embedded in the access
  // unit (re)create the decode session automatically.
  //
  // The returned pixel buffer is NOT locked — the caller may lock it or hand
  // it straight to another VideoToolbox/CoreVideo consumer.
  auto decode(std::span<const uint8_t> annexBData, uint64_t pts) -> CVPixelBufferRef;

  // Drain any delayed frames and reset internal latency. Called on network
  // glitches (video_flush / conn_reset) to stop buffered frames piling up.
  auto flush() -> void;

private:
  // VideoToolbox callback invoked synchronously from decode().
  static void onDecoded(void *decompRefCon,
                        void *sourceRefCon,
                        OSStatus status,
                        VTDecodeInfoFlags flags,
                        CVImageBufferRef imageBuffer,
                        CMTime pts,
                        CMTime dur);

  auto ensureSession(std::span<const uint8_t> sps, std::span<const uint8_t> pps) -> bool;

  // Serializes decode() (decoder thread) against flush() and ~H264DecoderVT (UxPlay callback threads:
  // conn_reset / video_flush / video_reset). Without it, flush() frees pendingBuffer_ / invalidates
  // session_ concurrently with a decode → use-after-free + double-free on a mirror drop/glitch.
  // onDecoded runs synchronously inside decode() (already under this lock), so it needs no lock.
  std::mutex mutex_;

  CMVideoFormatDescriptionRef formatDesc_ = nullptr;
  VTDecompressionSessionRef session_ = nullptr;

  std::vector<uint8_t> lastSps_;
  std::vector<uint8_t> lastPps_;

  // Set by onDecoded callback during the synchronous decode call. Retained
  // there, consumed (handed to caller) at the end of decode().
  CVPixelBufferRef pendingBuffer_ = nullptr;
  OSStatus pendingStatus_ = noErr;

  bool firstFrameLogged_ = false;
};
