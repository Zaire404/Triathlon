#pragma once

#include <cstdint>

namespace npc {

// Memory / MMIO map used by simulator and boot chain.
inline constexpr uint32_t kPmemBase = 0x80000000u;
inline constexpr uint32_t kPmemSize = 0x08000000u;  // 128 MiB

inline constexpr uint32_t kBootRomBase = 0x00001000u;
inline constexpr uint32_t kBootRomSize = 0x00001000u;
inline constexpr uint32_t kDtbBase = 0x87F00000u;

inline constexpr uint32_t kClintBase = 0x02000000u;
inline constexpr uint32_t kClintMtimecmpLow = kClintBase + 0x00004000u;
inline constexpr uint32_t kClintMtimecmpHigh = kClintBase + 0x00004004u;
inline constexpr uint32_t kClintMtimeLow = kClintBase + 0x0000BFF8u;
inline constexpr uint32_t kClintMtimeHigh = kClintBase + 0x0000BFFCu;
inline constexpr uint32_t kPlicBase = 0x0C000000u;
inline constexpr uint32_t kUartBase = 0xA0000000u;
inline constexpr uint32_t kUartTx = 0xA00003F8u;
inline constexpr uint32_t kSerialPort = kUartTx;
inline constexpr uint32_t kRtcPortLow = 0xA0000048u;
inline constexpr uint32_t kRtcPortHigh = 0xA000004Cu;

inline constexpr uint32_t kSeed4Addr = 0x80003C3Cu;

struct BootHandoff {
  uint32_t hartid;
  uint32_t dtb_addr;
  uint32_t satp;
};

inline constexpr BootHandoff make_default_boot_handoff() {
  return BootHandoff{0u, kDtbBase, 0u};
}

}  // namespace npc
