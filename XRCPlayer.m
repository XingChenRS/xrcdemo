// XRCPlayer.m — 音频：registry/player/channel/进度/曲长（单一数据源）。
// 6.13 版本的位置跟踪有双通道（vtable hook + 0.5s 轮询 NSTimer 同时更新同一批原子量，
// 各维护一份换歌检测）——此处收敛：hook 为唯一更新源，Tweak.x 轮询仅做兜底捕获。

#import <Foundation/Foundation.h>
#import "XRCLog.h"    // xrc_log
#include <limits.h>
#include "XRCPlayer.h"
#include "XRCGameplay.h"   // xrc_swizzle_vtable（同 dylib 内跨模块）
#include "XRCRuntime.h"
#include "XRCProfile.h"

typedef void *(*get_registry_fn)(void);
typedef int    (*get_current_sound_fn)(void *channel, void **outSound);
typedef int    (*get_sound_length_fn)(void *sound, uint32_t *outLen, int unit);
typedef int    (*ch_get_position_fn)(void *channel, uint32_t *out_ms, int unit);

static get_registry_fn      s_get_registry      = NULL;
static get_current_sound_fn s_get_current_sound = NULL;
static get_sound_length_fn  s_get_sound_length  = NULL;
static ch_get_position_fn   s_ch_get_position   = NULL;

static _Atomic(void *)   s_bgm_player  = NULL;
static _Atomic(uint32_t) s_last_pos_ms = 0;
static _Atomic(uint32_t) s_max_seen_ms = 0;
static _Atomic(uint32_t) s_song_len_ms = 0;

// MTP getpos vtable hook（位置缓存唯一更新源）。7.0 单参 (self, channel)。
static uint32_t (*s_orig_mtp_getpos)(void *self, int channel) = NULL;

static uint32_t s_tw_mtp_getpos(void *self, int channel) {
    uint32_t raw = s_orig_mtp_getpos ? s_orig_mtp_getpos(self, channel) : 0;
    if (channel == 0)
        xrc_player_update_position(self, raw);
    return raw;
}

// ---- 安装（Tweak.x 引导时调用一次） ----
void xrc_player_install(uint64_t image_base) {
    if (g_xrc.mtp_vtable && g_xrc.mtp_getpos) {
        // 运行时锚点（info blob 重定位）优先
        int slot = xrc_swizzle_vtable(g_xrc.mtp_vtable,
                                      g_xrc.mtp_getpos - g_xrc.image_base,
                                      (void *)s_tw_mtp_getpos,
                                      (void **)&s_orig_mtp_getpos);
        if (slot != INT_MIN)
            xrc_log(@"mtp.getpos vtable installed slot=%d (runtime anchor)", slot);
    } else if (XRC_OFF_MTP_VTABLE != 0 && XRC_OFF_MTP_GETPOS != 0) {
        // 编译期 profile fallback
        extern uint64_t xrc_image_base(void);
        int slot = xrc_swizzle_vtable(xrc_image_base() + XRC_OFF_MTP_VTABLE,
                                      XRC_OFF_MTP_GETPOS,
                                      (void *)s_tw_mtp_getpos,
                                      (void **)&s_orig_mtp_getpos);
        if (slot != INT_MIN)
            xrc_log(@"mtp.getpos vtable installed slot=%d (profile fallback)", slot);
    }
    if (XRC_OFF_CH_GET_POSITION)   s_ch_get_position   = (ch_get_position_fn)  (image_base + XRC_OFF_CH_GET_POSITION);
    if (XRC_OFF_GET_CURRENT_SOUND) s_get_current_sound = (get_current_sound_fn)(image_base + XRC_OFF_GET_CURRENT_SOUND);
    if (XRC_OFF_GET_SOUND_LENGTH)  s_get_sound_length  = (get_sound_length_fn) (image_base + XRC_OFF_GET_SOUND_LENGTH);
    if (XRC_OFF_GET_REGISTRY)      s_get_registry      = (get_registry_fn)     (image_base + XRC_OFF_GET_REGISTRY);
}

void *xrc_player_get(void) {
    void *p = atomic_load(&s_bgm_player);
    if (p) return p;
    if (!s_get_registry) return NULL;
    void *reg = s_get_registry();
    if (!reg) return NULL;
    void *mtp = *(void **)((char *)reg + XRC_REG_PLAYER_OFF);
    if (mtp) atomic_store(&s_bgm_player, mtp);
    return mtp;
}

// vtable hook（MTP getpos 槽）专用：更新缓存 + 换歌检测。
void xrc_player_update_position(void *self, uint32_t pos) {
    atomic_store(&s_bgm_player, self);
    atomic_store(&s_last_pos_ms, pos);
    uint32_t prev = atomic_exchange(&s_max_seen_ms, pos);
    if (prev > 100 && pos < 100) {
        atomic_store(&s_song_len_ms, 0);
    } else if (pos > atomic_load(&s_max_seen_ms)) {
        atomic_store(&s_max_seen_ms, pos);
    }
}

uint32_t xrc_player_song_length_ms(void) {
    uint32_t len = atomic_load(&s_song_len_ms);
    return len ? len : atomic_load(&s_max_seen_ms);
}

uint32_t xrc_player_position_ms(void) {
    return atomic_load(&s_last_pos_ms);
}

void xrc_player_try_capture_length(void *player) {
    if (!player) return;
    if (atomic_load(&s_song_len_ms) != 0) return;
    void *channels = *(void **)((char *)player + XRC_PLAYER_CHANNELS_OFF);
    if (!channels) return;
    void *ch0 = *(void **)((char *)channels + XRC_CHANNEL_ENTRY_PTR_OFF);
    if (!ch0) return;
    void *snd = NULL;
    if (!s_get_current_sound) return;
    if (s_get_current_sound(ch0, &snd) != 0 || !snd) return;
    uint32_t len = 0;
    if (s_get_sound_length && s_get_sound_length(snd, &len, 1) == 0 &&
        len > 0 && len < 0x7FFFFFFFu) {
        atomic_store(&s_song_len_ms, len);
        return;
    }
    // 静态 get_sound_length 未定位 → 运行时 vtable 尝试
    // （6.13 已验证 Sound 对象 vtable 槽 19 = getLength(sound, out, unit)）
    void **svt = *(void ***)snd;
    if (!svt) return;
    typedef int (*sound_len_fn)(void *, uint32_t *, int);
    sound_len_fn fn = (sound_len_fn)svt[19];
    if (fn && fn(snd, &len, 1) == 0 && len > 0 && len < 0x7FFFFFFFu)
        atomic_store(&s_song_len_ms, len);
}

// 位置轮询兜底：channel 0 的 get_position（getpos hook 不频繁触发时的补充）
void xrc_player_poll_position(void *player) {
    if (!player || !s_ch_get_position) return;
    void *channels = *(void **)((char *)player + XRC_PLAYER_CHANNELS_OFF);
    if (!channels) return;
    void *ch0 = *(void **)((char *)channels + XRC_CHANNEL_ENTRY_PTR_OFF);
    if (!ch0) return;
    uint32_t pos = 0;
    if (s_ch_get_position(ch0, &pos, 1) == 0) {
        atomic_store(&s_last_pos_ms, pos);
        uint32_t prev = atomic_load(&s_max_seen_ms);
        if (pos > prev) atomic_store(&s_max_seen_ms, pos);
    }
}

bool xrc_player_detect_change(void *player) {
    static void *s_last_player = NULL;
    static void *s_last_channels = NULL;
    void *channels = player ? *(void **)((char *)player + XRC_PLAYER_CHANNELS_OFF) : NULL;
    if (player == s_last_player && channels == s_last_channels) return false;
    atomic_store(&s_song_len_ms, 0);
    atomic_store(&s_max_seen_ms, 0);
    atomic_store(&s_last_pos_ms, 0);
    s_last_player = player;
    s_last_channels = channels;
    return true;
}

bool xrc_player_seek_ms(void *self, uint32_t ms) {
    if (!self) return false;
    typedef void (*seek_fn)(void *, uint32_t, int);
    void **vtable = *(void ***)self;
    if (!vtable) return false;
    seek_fn fn = (seek_fn)vtable[XRC_PLAYER_SEEK_SLOT_OFF / sizeof(void *)];
    if (!fn) return false;
    fn(self, ms, 0);
    return true;
}
