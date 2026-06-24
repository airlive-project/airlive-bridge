#include "H264DecoderVT.hpp"

#import <os/log.h>

#include <arpa/inet.h>
#include <cstring>

static os_log_t vt_log()
{
  static os_log_t log = os_log_create("studio.airlive.bridge.airplay", "H264DecoderVT");
  return log;
}

namespace {

// Walk an Annex B bytestream. Returns (offset, size, nal_type) for each NAL.
// We support 4-byte start codes (00 00 00 01) since that's what UxPlay produces;
// 3-byte (00 00 01) start codes are also accepted defensively.
struct Nalu
{
  size_t offset;
  size_t size;
  uint8_t type;
};

auto walkAnnexB(const uint8_t *data, size_t len) -> std::vector<Nalu>
{
  std::vector<Nalu> out;
  out.reserve(8);

  auto isStartCode4 = [&](size_t i) {
    return i + 4 <= len && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1;
  };
  auto isStartCode3 = [&](size_t i) {
    return i + 3 <= len && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1;
  };

  size_t i = 0;
  while (i < len)
  {
    size_t scLen = 0;
    if (isStartCode4(i))
      scLen = 4;
    else if (isStartCode3(i))
      scLen = 3;
    else
    {
      ++i;
      continue;
    }

    size_t naluStart = i + scLen;
    // Find next start code.
    size_t j = naluStart;
    while (j < len)
    {
      if (isStartCode4(j) || isStartCode3(j))
        break;
      ++j;
    }
    if (naluStart < len)
    {
      out.push_back({naluStart, j - naluStart, static_cast<uint8_t>(data[naluStart] & 0x1F)});
    }
    i = j;
  }
  return out;
}

// Convert Annex B → length-prefixed (avcC). Skips SPS (7), PPS (8) and AUD (9):
// SPS/PPS go in via the CMVideoFormatDescription, not inline.
auto annexBToAvcc(const uint8_t *src, const std::vector<Nalu> &nalus) -> std::vector<uint8_t>
{
  size_t total = 0;
  for (const auto &n : nalus)
    if (n.type != 7 && n.type != 8 && n.type != 9)
      total += 4 + n.size;

  std::vector<uint8_t> out;
  out.reserve(total);
  for (const auto &n : nalus)
  {
    if (n.type == 7 || n.type == 8 || n.type == 9)
      continue;
    uint32_t lenBE = htonl(static_cast<uint32_t>(n.size));
    out.insert(out.end(), reinterpret_cast<uint8_t *>(&lenBE), reinterpret_cast<uint8_t *>(&lenBE) + 4);
    out.insert(out.end(), src + n.offset, src + n.offset + n.size);
  }
  return out;
}

} // namespace

void H264DecoderVT::onDecoded(void *decompRefCon,
                              void * /*sourceRefCon*/,
                              OSStatus status,
                              VTDecodeInfoFlags /*flags*/,
                              CVImageBufferRef imageBuffer,
                              CMTime /*pts*/,
                              CMTime /*dur*/)
{
  auto *self = static_cast<H264DecoderVT *>(decompRefCon);
  self->pendingStatus_ = status;
  if (status != noErr || imageBuffer == nullptr)
    return;
  // VT hands us a non-owning ref valid only during this callback. Retain so we
  // can pass ownership out of decode() to the caller.
  self->pendingBuffer_ = imageBuffer;
  CVPixelBufferRetain(self->pendingBuffer_);
}

H264DecoderVT::H264DecoderVT() = default;

H264DecoderVT::~H264DecoderVT()
{
  if (session_)
  {
    VTDecompressionSessionInvalidate(session_);
    CFRelease(session_);
    session_ = nullptr;
  }
  if (formatDesc_)
  {
    CFRelease(formatDesc_);
    formatDesc_ = nullptr;
  }
}

auto H264DecoderVT::ensureSession(std::span<const uint8_t> sps, std::span<const uint8_t> pps) -> bool
{
  // Reuse the existing session if SPS/PPS are unchanged.
  if (session_ && lastSps_.size() == sps.size() && lastPps_.size() == pps.size() &&
      std::memcmp(lastSps_.data(), sps.data(), sps.size()) == 0 &&
      std::memcmp(lastPps_.data(), pps.data(), pps.size()) == 0)
    return true;

  // Tear down the old session.
  if (session_)
  {
    VTDecompressionSessionInvalidate(session_);
    CFRelease(session_);
    session_ = nullptr;
  }
  if (formatDesc_)
  {
    CFRelease(formatDesc_);
    formatDesc_ = nullptr;
  }

  // Build a CMVideoFormatDescription from SPS+PPS.
  const uint8_t *params[2] = {sps.data(), pps.data()};
  const size_t paramSizes[2] = {sps.size(), pps.size()};
  OSStatus s = CMVideoFormatDescriptionCreateFromH264ParameterSets(
    kCFAllocatorDefault, 2, params, paramSizes, 4, &formatDesc_);
  if (s != noErr)
  {
    os_log_error(vt_log(), "CMVideoFormatDescriptionCreateFromH264ParameterSets failed: %d", (int)s);
    return false;
  }

  // Decoder spec — request hardware acceleration.
  CFMutableDictionaryRef decoderSpec = CFDictionaryCreateMutable(
    kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(decoderSpec,
                       kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder,
                       kCFBooleanTrue);

  // Destination pixel buffer attributes — NV12 (biplanar YCbCr 4:2:0, video range).
  CFMutableDictionaryRef dstAttrs = CFDictionaryCreateMutable(
    kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  int32_t pixFmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
  CFNumberRef pixFmtNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pixFmt);
  CFDictionarySetValue(dstAttrs, kCVPixelBufferPixelFormatTypeKey, pixFmtNum);
  CFRelease(pixFmtNum);
  // Request Metal-compatible buffers so a downstream renderer can bridge the
  // planes via CVMetalTextureCache with zero copies.
  CFDictionarySetValue(dstAttrs, kCVPixelBufferMetalCompatibilityKey, kCFBooleanTrue);

  VTDecompressionOutputCallbackRecord cb = {&H264DecoderVT::onDecoded, this};
  s = VTDecompressionSessionCreate(
    kCFAllocatorDefault, formatDesc_, decoderSpec, dstAttrs, &cb, &session_);
  CFRelease(decoderSpec);
  CFRelease(dstAttrs);

  if (s != noErr)
  {
    os_log_error(vt_log(), "VTDecompressionSessionCreate failed: %d", (int)s);
    CFRelease(formatDesc_);
    formatDesc_ = nullptr;
    return false;
  }

  // Real-time hint — lower-latency decoder path.
  VTSessionSetProperty(session_, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);

  lastSps_.assign(sps.begin(), sps.end());
  lastPps_.assign(pps.begin(), pps.end());

  os_log(vt_log(), "decoder session created, SPS=%dB PPS=%dB", (int)sps.size(), (int)pps.size());
  return true;
}

auto H264DecoderVT::decode(std::span<const uint8_t> data, uint64_t pts) -> CVPixelBufferRef
{
  auto nalus = walkAnnexB(data.data(), data.size());
  if (nalus.empty())
    return nullptr;

  // Extract SPS/PPS if present in this packet.
  std::span<const uint8_t> sps, pps;
  for (const auto &n : nalus)
  {
    if (n.type == 7)
      sps = {data.data() + n.offset, n.size};
    else if (n.type == 8)
      pps = {data.data() + n.offset, n.size};
  }

  // If this packet carries SPS+PPS, (re)create the session.
  if (!sps.empty() && !pps.empty())
  {
    if (!ensureSession(sps, pps))
      return nullptr;
  }

  if (!session_)
    return nullptr; // not yet ready — waiting for a keyframe with SPS/PPS

  auto avcc = annexBToAvcc(data.data(), nalus);
  if (avcc.empty())
    return nullptr; // packet was only SPS/PPS; format desc updated, nothing to decode

  // Wrap the avcC payload in a CMBlockBuffer. We point VT directly at our
  // vector's memory (kCFAllocatorNull = VT does not own it); the vector
  // outlives the synchronous decode call, so this is safe and avoids a copy.
  CMBlockBufferRef blockBuf = nullptr;
  OSStatus s = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                  const_cast<uint8_t *>(avcc.data()),
                                                  avcc.size(),
                                                  kCFAllocatorNull,
                                                  nullptr,
                                                  0,
                                                  avcc.size(),
                                                  0,
                                                  &blockBuf);
  if (s != noErr)
  {
    os_log_error(vt_log(), "CMBlockBufferCreateWithMemoryBlock failed: %d", (int)s);
    return nullptr;
  }

  // Wrap in a CMSampleBuffer.
  CMSampleBufferRef sampleBuf = nullptr;
  const size_t sampleSize = avcc.size();
  s = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                blockBuf,
                                formatDesc_,
                                1,
                                0,
                                nullptr,
                                1,
                                &sampleSize,
                                &sampleBuf);
  CFRelease(blockBuf);
  if (s != noErr)
  {
    os_log_error(vt_log(), "CMSampleBufferCreateReady failed: %d", (int)s);
    return nullptr;
  }

  // Synchronous decode — onDecoded fires before this returns.
  pendingBuffer_ = nullptr;
  pendingStatus_ = noErr;
  VTDecodeFrameFlags flags = 0; // synchronous
  VTDecodeInfoFlags info = 0;
  s = VTDecompressionSessionDecodeFrame(session_, sampleBuf, flags, nullptr, &info);
  CFRelease(sampleBuf);

  if (s != noErr)
  {
    os_log_error(vt_log(), "VTDecompressionSessionDecodeFrame failed: %d", (int)s);
    if (pendingBuffer_)
    {
      CVPixelBufferRelease(pendingBuffer_);
      pendingBuffer_ = nullptr;
    }
    return nullptr;
  }
  if (pendingStatus_ != noErr || !pendingBuffer_)
    return nullptr;

  // Hand the retained buffer to the caller. Clear our pointer first so flush()
  // / a later decode never double-releases it.
  CVPixelBufferRef out = pendingBuffer_;
  pendingBuffer_ = nullptr;

  if (!firstFrameLogged_)
  {
    os_log(vt_log(), "first decoded frame %dx%d",
           (int)CVPixelBufferGetWidth(out), (int)CVPixelBufferGetHeight(out));
    firstFrameLogged_ = true;
  }

  (void)pts; // pts is carried alongside the buffer by the caller (VideoPacket).
  return out;
}

auto H264DecoderVT::flush() -> void
{
  if (pendingBuffer_)
  {
    CVPixelBufferRelease(pendingBuffer_);
    pendingBuffer_ = nullptr;
  }
  if (session_)
    VTDecompressionSessionFinishDelayedFrames(session_);
}
