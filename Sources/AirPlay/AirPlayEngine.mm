//
// AirPlayEngine.mm — standalone, OBS-free, video-only AirPlay receiver.
//
// A strip-and-adapt of the proven obs-airlive plugin's airplay.cpp VIDEO path
// onto the modern UxPlay (fduncanh fork) C library that ships prebuilt in
// Vendor/airplay-lib. OBS coupling (obs_source_frame, obs_data, blog) is gone;
// audio is discarded; only the UxPlay lib + VideoToolbox/CoreVideo/CoreMedia +
// libc++ are used.
//
// THREADING (critical — inherited from the plugin's hard-won lesson):
//   • UxPlay invokes our callbacks (video_process, conn_*) on its own network
//     threads. Those callbacks must NEVER call raop_destroy: raop_destroy joins
//     the mirror thread, and calling it from a UxPlay-managed thread yields
//     pthread_join(self) → EDEADLK and a use-after-free in the logger.
//   • A dedicated `restartWorker` std::thread owns ALL raop_destroy / restart /
//     teardown calls. Callbacks merely set an atomic `needsRestart` and notify.
//   • setAdvertiseName: and stop route through that worker too (serverMutex
//     serialises every start/stop/restart).
//
// PIPELINE (decoupled decode):
//   network thread → video_process copies bytes+pts into an owning VideoPacket
//   → BoundedQueue (drop-oldest) → decoder thread → H264DecoderVT::decode →
//   onVideoFrame(pixelBuffer, ptsNs) → release. Decoupling stops a slow decoder
//   from back-pressuring TCP (the obs-airplay/RPiPlay "growing latency" bug).
//

#import "AirPlayEngine.h"

#import <os/log.h>

#include <atomic>
#include <condition_variable>
#include <cstring>
#include <ctime>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <ifaddrs.h>
#include <net/if_dl.h>
#include <sys/socket.h>
#include <unistd.h>

#include "H264DecoderVT.hpp"
#include "bounded_queue.hpp"

extern "C" {
#include "dnssd.h"
#include "logger.h"
#include "raop.h"
#include "stream.h"
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

static os_log_t ap_log()
{
  static os_log_t log = os_log_create("studio.airlive.bridge.airplay", "AirPlayEngine");
  return log;
}

// ---------------------------------------------------------------------------
// Owning packet copied off the network thread before queueing (UxPlay frees
// the underlying bytes as soon as video_process returns).
// ---------------------------------------------------------------------------

namespace {

struct VideoPacket
{
  std::vector<uint8_t> data;
  uint64_t pts = 0; // nanoseconds (ntp_time_remote from the mirror stream)
  int nal_count = 0;
};

// MAC-address helpers — ported from airplay.cpp (macOS branch only).
#define MULTICAST 0
#define LOCAL 1
#define OCTETS 6

std::string random_mac()
{
  char str[3];
  int octet = rand() % 64;
  octet = (octet << 1) + LOCAL;
  octet = (octet << 1) + MULTICAST;
  snprintf(str, 3, "%02x", octet);
  std::string mac_address(str);
  for (int i = 1; i < OCTETS; i++)
  {
    mac_address = mac_address + ":";
    octet = rand() % 256;
    snprintf(str, 3, "%02x", octet);
    mac_address = mac_address + str;
  }
  return mac_address;
}

std::string find_mac()
{
  std::string mac;
  struct ifaddrs *ifap = nullptr;
  if (getifaddrs(&ifap) != 0)
    return mac;
  for (struct ifaddrs *p = ifap; p != nullptr; p = p->ifa_next)
  {
    if (p->ifa_addr == nullptr || p->ifa_addr->sa_family != AF_LINK)
      continue;
    unsigned char *ptr = (unsigned char *)LLADDR((struct sockaddr_dl *)p->ifa_addr);
    int non_null = 0;
    unsigned char octet[6];
    for (int i = 0; i < 6; i++)
    {
      octet[i] = ptr[i];
      if (octet[i] != 0)
        non_null++;
    }
    if (non_null)
    {
      char str[3];
      for (int i = 0; i < 6; i++)
      {
        snprintf(str, sizeof(str), "%02x", octet[i]);
        mac += str;
        if (i < 5)
          mac += ":";
      }
      break;
    }
  }
  freeifaddrs(ifap);
  return mac;
}

int parse_hw_addr(const std::string &str, std::vector<char> &hw_addr)
{
  for (size_t i = 0; i < str.length(); i += 3)
    hw_addr.push_back((char)strtol(str.substr(i).c_str(), nullptr, 16));
  return 0;
}

} // namespace

// ---------------------------------------------------------------------------
// C++ engine implementation (the ObjC class is a thin shell around this).
// ---------------------------------------------------------------------------

class AirPlayEngineImpl
{
public:
  using FrameCallback = void (^)(CVPixelBufferRef, uint64_t);

  explicit AirPlayEngineImpl(std::string name) : serverName_(std::move(name)) {}

  ~AirPlayEngineImpl() { stop(); }

  void setFrameCallback(FrameCallback cb)
  {
    std::lock_guard<std::mutex> lk(cbMutex_);
    frameCb_ = cb; // ObjC block; ARC retains on copy in the property setter
  }

  void start()
  {
    std::lock_guard<std::mutex> lk(serverMutex_);
    if (running_)
      return;

    // Decoder thread first so it's ready before frames arrive.
    decoderThread_ = std::thread(&AirPlayEngineImpl::decoderLoop, this);

    if (startServerLocked(serverName_) != 0)
    {
      os_log_error(ap_log(), "start: failed to bring up AirPlay server");
      // Decoder thread is harmless idle; leave it for stop() to clean up.
    }

    // Restart worker owns all teardown/restart so callbacks never join self.
    restartWorker_ = std::thread(&AirPlayEngineImpl::restartWorkerLoop, this);
    running_ = true;
    os_log(ap_log(), "AirPlay engine started as \"%{public}s\"", serverName_.c_str());
  }

  void stop()
  {
    {
      std::lock_guard<std::mutex> lk(serverMutex_);
      if (!running_)
        return;
      running_ = false;
    }

    // 1) Shut down the restart worker BEFORE tearing the server down, so a
    //    queued restart can't race our own teardown.
    {
      std::lock_guard<std::mutex> lk(restartMutex_);
      restartWorkerExit_ = true;
    }
    restartCv_.notify_all();
    if (restartWorker_.joinable())
      restartWorker_.join();

    // 2) Stop the server → no more callbacks → no more enqueues.
    {
      std::lock_guard<std::mutex> lk(serverMutex_);
      stopServerLocked();
    }

    // 3) Close the queue and join the decoder (drains remaining frames, then
    //    sees the closed flag and exits).
    videoQueue_.close();
    if (decoderThread_.joinable())
      decoderThread_.join();

    os_log(ap_log(), "AirPlay engine stopped");
  }

  // Route a name change through the worker so the destroy/restart never runs
  // on a UxPlay thread.
  void setAdvertiseName(std::string name)
  {
    {
      std::lock_guard<std::mutex> lk(restartMutex_);
      pendingName_ = std::move(name);
      hasPendingName_ = true;
      needsRestart_ = true;
    }
    restartCv_.notify_one();
  }

  // ---- static UxPlay callbacks (cls == this) ----

  static void conn_init(void *cls)
  {
    auto *self = static_cast<AirPlayEngineImpl *>(cls);
    self->openConnections_++;
    os_log(ap_log(), "conn_init — open connections: %d", self->openConnections_.load());
  }

  static void conn_destroy(void *cls)
  {
    auto *self = static_cast<AirPlayEngineImpl *>(cls);
    if (self->openConnections_ > 0)
      self->openConnections_--;
    os_log(ap_log(), "conn_destroy — open connections: %d", self->openConnections_.load());
  }

  static void conn_reset(void *cls, int reason)
  {
    auto *self = static_cast<AirPlayEngineImpl *>(cls);
    os_log(ap_log(), "conn_reset — lost connection (reason %d)", reason);
    self->decoder_.flush();
    // MUST NOT raop_destroy here — this runs on a UxPlay thread. Defer.
    self->requestRestart();
  }

  static void conn_teardown(void * /*cls*/, bool *teardown_96, bool *teardown_110)
  {
    os_log(ap_log(), "conn_teardown (%d,%d)", teardown_96 ? *teardown_96 : 0,
           teardown_110 ? *teardown_110 : 0);
  }

  static void video_process(void *cls, raop_ntp_t * /*ntp*/, video_decode_struct *data)
  {
    auto *self = static_cast<AirPlayEngineImpl *>(cls);
    VideoPacket pkt;
    pkt.data.assign(data->data, data->data + data->data_len);
    // This UxPlay fork carries the presentation time as ntp_time_remote (ns);
    // there is no separate `pts` field as in the older obs-airplay struct.
    pkt.pts = data->ntp_time_remote;
    pkt.nal_count = data->nal_count;
    self->videoDropCount_ += self->videoQueue_.push(std::move(pkt));
  }

  static void video_flush(void *cls)
  {
    auto *self = static_cast<AirPlayEngineImpl *>(cls);
    os_log(ap_log(), "video_flush");
    self->decoder_.flush();
  }

  // --- audio: minimal discard stubs (raop_init asserts audio_process != NULL) ---

  static void audio_process(void * /*cls*/, raop_ntp_t * /*ntp*/, audio_decode_struct * /*data*/)
  {
    // Video-only. Discard audio entirely (no decode, no fdk-aac).
  }

  static void audio_flush(void * /*cls*/) {}

  static void audio_set_volume(void * /*cls*/, float /*volume*/) {}

  static void audio_get_format(void * /*cls*/,
                               unsigned char *ct,
                               unsigned short * /*spf*/,
                               bool * /*usingScreen*/,
                               bool * /*isMedia*/,
                               uint64_t * /*audioFormat*/)
  {
    // Acknowledge a compression type so the client proceeds with the session,
    // then ignore all audio. ct==1 is the LPCM/screen default.
    if (ct)
      *ct = 1;
  }

  static void video_report_size(void *cls,
                                float *width_source,
                                float *height_source,
                                float * /*width*/,
                                float * /*height*/)
  {
    auto *self = static_cast<AirPlayEngineImpl *>(cls);
    if (width_source)
      self->width_ = (int)*width_source;
    if (height_source)
      self->height_ = (int)*height_source;
    os_log(ap_log(), "video_report_size %dx%d", self->width_, self->height_);
  }

  static void log_callback(void * /*cls*/, int level, const char *msg)
  {
    switch (level)
    {
    case LOGGER_ERR: os_log_error(ap_log(), "[uxplay] %{public}s", msg); break;
    case LOGGER_WARNING: os_log(ap_log(), "[uxplay W] %{public}s", msg); break;
    case LOGGER_INFO: os_log(ap_log(), "[uxplay I] %{public}s", msg); break;
    default: os_log_debug(ap_log(), "[uxplay D] %{public}s", msg); break;
    }
  }

private:
  // ---- decoder thread ----

  void decoderLoop()
  {
    os_log(ap_log(), "decoder thread started");
    while (true)
    {
      auto pkt = videoQueue_.pop();
      if (!pkt)
        break; // queue closed and drained
      CVPixelBufferRef buf = decoder_.decode(pkt->data, pkt->pts);
      if (!buf)
        continue;
      FrameCallback cb;
      {
        std::lock_guard<std::mutex> lk(cbMutex_);
        cb = frameCb_;
      }
      if (cb)
        cb(buf, pkt->pts);
      CVPixelBufferRelease(buf);
    }
    os_log(ap_log(), "decoder thread exiting");
  }

  // ---- restart worker (owns every raop_destroy/restart) ----

  void requestRestart()
  {
    needsRestart_ = true;
    restartCv_.notify_one();
  }

  void restartWorkerLoop()
  {
    while (true)
    {
      std::string nameForRestart;
      bool doNameChange = false;
      {
        std::unique_lock<std::mutex> lk(restartMutex_);
        restartCv_.wait(lk, [this] {
          return restartWorkerExit_.load() || needsRestart_.load();
        });
        if (restartWorkerExit_.load())
          return;
        if (!needsRestart_.exchange(false))
          continue;
        if (hasPendingName_)
        {
          nameForRestart = pendingName_;
          doNameChange = true;
          hasPendingName_ = false;
        }
      }

      std::lock_guard<std::mutex> lk(serverMutex_);
      if (!running_)
        continue; // stop() is in progress / done
      os_log(ap_log(), "restart worker: restarting AirPlay server%{public}s",
             doNameChange ? " (name change)" : "");
      stopServerLocked();
      if (doNameChange)
        serverName_ = nameForRestart;
      if (startServerLocked(serverName_) != 0)
        os_log_error(ap_log(), "restart worker: start failed");
    }
  }

  // ---- server lifecycle (caller holds serverMutex_) ----
  // Mirrors uxplay.cpp's proven order: dnssd_init → raop_init(+init2) →
  // ports/httpd → raop_set_dnssd → dnssd_register_{raop,airplay}.

  int startServerLocked(const std::string &name)
  {
    // Resolve a MAC (system MAC preferred; fall back to random).
    std::string mac = find_mac();
    if (mac.empty())
    {
      srand((unsigned)(time(nullptr) * getpid()));
      mac = random_mac();
      os_log(ap_log(), "using random MAC %{public}s", mac.c_str());
    }
    std::vector<char> hwAddr;
    parse_hw_addr(mac, hwAddr);

    // 1) dnssd first — raop_set_dnssd below requires it non-null.
    int err = 0;
    // pin_pw = 0: no client access control (open receiver).
    dnssd_ = dnssd_init(name.c_str(), (int)strlen(name.c_str()),
                        hwAddr.data(), (int)hwAddr.size(), 0, &err);
    if (err || !dnssd_)
    {
      os_log_error(ap_log(), "dnssd_init failed: %d", err);
      return -1;
    }
    // Advertise the mirroring-capable feature set (matches uxplay.cpp). The
    // lib's defaults already enable mirroring (bit 7); we set the essentials
    // explicitly so behaviour doesn't drift with the lib's default constant.
    dnssd_set_airplay_features(dnssd_, 0, 0);  // AirPlay video
    dnssd_set_airplay_features(dnssd_, 7, 1);  // mirroring supported
    dnssd_set_airplay_features(dnssd_, 9, 1);  // audio supported (advertised; discarded)
    dnssd_set_airplay_features(dnssd_, 11, 1); // audio packet redundancy
    dnssd_set_airplay_features(dnssd_, 14, 1); // FairPlay authentication
    dnssd_set_airplay_features(dnssd_, 30, 1); // RAOP support

    // 2) raop_init — wire callbacks (cls == this). audio_process + video_process
    //    MUST be non-null or raop_init returns NULL.
    raop_callbacks_t cbs;
    memset(&cbs, 0, sizeof(cbs));
    cbs.cls = this;
    cbs.audio_process = audio_process;
    cbs.video_process = video_process;
    cbs.conn_init = conn_init;
    cbs.conn_destroy = conn_destroy;
    cbs.conn_reset = conn_reset;
    cbs.conn_teardown = conn_teardown;
    cbs.audio_flush = audio_flush;
    cbs.video_flush = video_flush;
    cbs.audio_set_volume = audio_set_volume;
    cbs.audio_get_format = audio_get_format;
    cbs.video_report_size = video_report_size;

    raop_ = raop_init(&cbs);
    if (!raop_)
    {
      os_log_error(ap_log(), "raop_init failed");
      stopServerLocked();
      return -2;
    }

    raop_set_log_callback(raop_, log_callback, nullptr);
    raop_set_log_level(raop_, LOGGER_INFO);

    // 3) raop_init2 — mandatory in this fork (sets up pairing + httpd).
    //    nohold = 1: let a new client take over from a stale connection.
    //    Empty keyfile → an ephemeral pairing key is generated in memory.
    if (raop_init2(raop_, /*nohold=*/1, mac.c_str(), /*keyfile=*/""))
    {
      os_log_error(ap_log(), "raop_init2 failed");
      stopServerLocked();
      return -3;
    }

    // 4) ports + httpd. 0-filled arrays = dynamic assignment.
    unsigned short tcp[3] = {0, 0, 0};
    unsigned short udp[3] = {0, 0, 0};
    raop_set_tcp_ports(raop_, tcp);
    raop_set_udp_ports(raop_, udp);

    unsigned short port = raop_get_port(raop_);
    raop_start_httpd(raop_, &port);
    raop_set_port(raop_, port);

    // 5) bind dnssd to raop. raop_set_dnssd() populates dnssd_->pk.
    raop_set_dnssd(raop_, dnssd_);
    // dnssd_register_* BUILDS the raop/airplay TXT records (TXTRecordCreate/SetValue)
    // as a side effect BEFORE its DNSServiceRegister call — and that call returns
    // -65555 (NoAuth) on macOS 26, which we IGNORE. We don't rely on dns_sd for
    // discovery; Swift advertises _raop._tcp/_airplay._tcp via NSNetService using the
    // TXT built here (read via the getters below). Without these calls the TXT records
    // are empty and the getters return nil → nothing gets advertised.
    int rcRaop = dnssd_register_raop(dnssd_, port);
    int rcAir = dnssd_register_airplay(dnssd_, port);
    os_log(ap_log(), "dnssd TXT built (dns_sd register rc raop=%d air=%d — ignored; NSNetService advertises)", rcRaop, rcAir);

    os_log(ap_log(), "AirPlay server up on port %d", (int)port);
    return 0;
  }

  void stopServerLocked()
  {
    if (raop_)
    {
      raop_destroy(raop_);
      raop_ = nullptr;
    }
    if (dnssd_)
    {
      // No dnssd_unregister_* — we never registered via dns_sd (NSNetService does
      // the advertising; the Swift side stops it). Just free the object.
      dnssd_destroy(dnssd_);
      dnssd_ = nullptr;
    }
  }

public:
  // --- Advertising data for the Swift NSNetService advertiser. Valid only AFTER
  //     startServerLocked (raop_set_dnssd populated dnssd_->pk + the TXT records). ---

  static NSDictionary<NSString *, NSData *> *parseDnsTxt(const char *txt, int len)
  {
    NSMutableDictionary<NSString *, NSData *> *d = [NSMutableDictionary dictionary];
    int i = 0;
    while (i < len)
    {
      int n = (unsigned char)txt[i++];          // DNS-TXT: [len][key=value]
      if (n == 0 || i + n > len) break;
      const char *e = txt + i;
      int eq = -1;
      for (int j = 0; j < n; j++) { if (e[j] == '=') { eq = j; break; } }
      if (eq >= 0)
      {
        NSString *k = [[NSString alloc] initWithBytes:e length:eq encoding:NSUTF8StringEncoding];
        if (k) d[k] = [NSData dataWithBytes:e + eq + 1 length:n - eq - 1];
      }
      i += n;
    }
    return d;
  }

  NSDictionary<NSString *, NSData *> *raopTxt()
  {
    if (!dnssd_) return nil;
    int len = 0; const char *t = dnssd_get_raop_txt(dnssd_, &len);
    return (t && len > 0) ? parseDnsTxt(t, len) : nil;
  }
  NSDictionary<NSString *, NSData *> *airplayTxt()
  {
    if (!dnssd_) return nil;
    int len = 0; const char *t = dnssd_get_airplay_txt(dnssd_, &len);
    return (t && len > 0) ? parseDnsTxt(t, len) : nil;
  }
  NSString *raopInstance()
  {
    if (!dnssd_) return nil;
    int len = 0; const char *hw = dnssd_get_hw_addr(dnssd_, &len);   // "HWADDR@name"
    NSMutableString *mac = [NSMutableString string];
    for (int i = 0; i < len; i++) [mac appendFormat:@"%02X", (unsigned char)hw[i]];
    return [NSString stringWithFormat:@"%@@%s", mac, dnssd_->name ?: ""];
  }
  NSString *airplayInstance()
  {
    return (dnssd_ && dnssd_->name) ? [NSString stringWithUTF8String:dnssd_->name] : nil;
  }
  uint16_t port() { return raop_ ? raop_get_port(raop_) : 0; }

private:
  // ---- state ----
  std::string serverName_;
  raop_t *raop_ = nullptr;
  dnssd_t *dnssd_ = nullptr;
  bool running_ = false;

  H264DecoderVT decoder_; // only ever touched by the decoder thread + flush()
  std::atomic<int> openConnections_{0};
  int width_ = 0;
  int height_ = 0;

  // Frame delivery.
  FrameCallback frameCb_ = nil;
  std::mutex cbMutex_;

  // Decoupled-decode queue. Size 8 caps worst-case added latency at ~265ms
  // @30fps / ~133ms @60fps (matches the obs-airlive plugin's tuned value).
  BoundedQueue<VideoPacket> videoQueue_{8};
  std::thread decoderThread_;
  std::atomic<uint64_t> videoDropCount_{0};

  // Restart worker.
  std::thread restartWorker_;
  std::mutex restartMutex_;
  std::condition_variable restartCv_;
  std::atomic<bool> needsRestart_{false};
  std::atomic<bool> restartWorkerExit_{false};
  std::string pendingName_;
  bool hasPendingName_ = false;

  std::mutex serverMutex_; // serialises start/stop/restart
};

// ---------------------------------------------------------------------------
// ObjC shell
// ---------------------------------------------------------------------------

@implementation AirPlayEngine
{
  AirPlayEngineImpl *_impl;
}

- (instancetype)initWithName:(NSString *)name
{
  self = [super init];
  if (self)
  {
    _impl = new AirPlayEngineImpl(std::string(name.UTF8String ?: "Airlive"));
  }
  return self;
}

- (void)dealloc
{
  delete _impl;
  _impl = nullptr;
}

- (void)setOnVideoFrame:(void (^)(CVPixelBufferRef, uint64_t))onVideoFrame
{
  _onVideoFrame = [onVideoFrame copy];
  _impl->setFrameCallback(_onVideoFrame);
}

- (void)start
{
  _impl->start();
}

- (void)stop
{
  _impl->stop();
}

- (void)setAdvertiseName:(NSString *)name
{
  _impl->setAdvertiseName(std::string(name.UTF8String ?: "Airlive"));
}

// --- advertising data for AirPlayBonjour (NSNetService); valid after -start ---
- (NSDictionary<NSString *, NSData *> *)raopTXTRecord { return _impl->raopTxt(); }
- (NSDictionary<NSString *, NSData *> *)airplayTXTRecord { return _impl->airplayTxt(); }
- (NSString *)raopInstanceName { return _impl->raopInstance(); }
- (NSString *)airplayInstanceName { return _impl->airplayInstance(); }
- (uint16_t)serverPort { return _impl->port(); }

@end
