# APM32F103CBT6 DAPLink 96MHz + WinUSB v2 + IAP 修复 + SWD 时钟修正

## 一、问题现象

**IAP 冷启动丢失（已修复）**

1. BL(72MHz) + IF(96MHz) 通过 IAP 拖入 IF CRC hex 后热启动正常
2. USB 拔插（冷启动）后回退到 MAINTENANCE 模式
3. 直接 SWD 刷 IF hex 则正常保持 DAPLink

**SWD 时钟偏差 3 倍（已修复）**

4. `pyocd -f 100K` 实际 SWCLK 只输出约 33kHz
5. `pyocd -f 1000K` 实际 SWCLK 只输出约 350kHz
6. 示波器确认：延时循环周期数未计入 Flash 等待周期(WS)

## 二、根因分析

### IAP 冷启动丢失

1. BL 中 `flash_regions[0].end` 设为 `0x08020000`（整片 128KB 结尾）
2. IAP 时 EraseChip 中 `NbPages` 误用 `%` 导致擦除 0 页
3. 旧数据残留 + 新数据覆盖 → IF CRC 校验失败
4. 冷启动后 IF 检测到配置无效 → 回退 MAINTENANCE

### SWD 时钟偏差

5. `DELAY_SLOW_CYCLES=3` 只计算了 CPU 指令周期（subs 1 + bne 2）
6. 未计入 96MHz × 3WS 下每条指令从 Flash 取指的额外等待
7. 实际每轮循环需 ~9 周期 → 输出频率为预期的 1/3

## 三、修改的文件（共 7 个）

### 1. `source/board/stm32f103xb_bl.c`

- 添加 `#include "daplink_addr.h"`
- `flash_regions[0].end`：
  - **修改前**：`0x08000000 + KB(128) = 0x08020000`（擦 80 页）
  - **修改后**：`DAPLINK_ROM_IF_START + DAPLINK_ROM_IF_SIZE = 0x0801FC00`（擦 79 页）
- **效果**：IAP 不再擦除配置区，配置区保留原始数据

### 2. `source/hic_hal/stm32/stm32f103xb/sdk.c`

- 添加 `FLASH_LATENCY_3` 宏定义（APM32 SDK 无此宏）
- 差异化时钟策略：
  - **BL**：`PLL_MUL9(72MHz) + FLASH_LATENCY_2` → IAP 兼容性好
  - **IF**：`PLL_MUL12(96MHz) + FLASH_LATENCY_3` → 调试速度快
- 添加 `__HAL_FLASH_PREFETCH_BUFFER_ENABLE()` 在切换时钟前
  （参考 APM32 SDK `SystemClock96M()` 的 `FMC->CTRL1_B.PBEN = BIT_SET`）
- IF 添加 USBDPSC 分频：`RCC->CFGR |= (1UL << 23)` → 96MHz / 2 = 48MHz

### 3. `source/hic_hal/stm32/stm32f103xb/flash.c`

- `EraseChip()` 中 `NbPages` 计算修复：
  - **修改前**：`(end - start) % FLASH_PAGE_SIZE`（错误，用了取模）
  - **修改后**：`(end - start) / FLASH_PAGE_SIZE`（正确，计算页数）
- **效果**：IAP 正确擦除 79 页（`0x0800C000 ~ 0x0801FBFF`）

### 4. `source/hic_hal/stm32/stm32f103xb/daplink_addr.h`

- `BL_SIZE = 0x0000C000`（48KB）
- `IF_SIZE = 0x00013C00`（79KB）紧邻配置区
- 配置区 = `0x0801FC00`，大小 `0x400`（1KB）
- BL=48KB, IF=79KB, Config=1KB = 128KB（完全填满）

### 5. `source/hic_hal/stm32/stm32f103xb/DAP_config.h`

- 添加 Flash 等待周期修正：
  - **BL**：`DELAY_SLOW_CYCLES=6, IO_PORT_WRITE_CYCLES=3`（72MHz, 2WS）
  - **IF**：`DELAY_SLOW_CYCLES=9, IO_PORT_WRITE_CYCLES=4`（96MHz, 3WS）
- **效果**：SWD 时钟与 `pyocd -f` 参数一致

### 6. `projects.yaml`

- `stm32f103xb_stm32f103rb_if` 添加 `records/usb/usb-bulk.yaml`
- **效果**：启用 CMSIS-DAP v2 WinUSB Bulk 端点，烧录速度提升 3-5 倍

### 7. `records/tools/gcc_arm.yaml`

- 移除 `-Wl,-fatal-warnings`，添加 `-Wl,--no-warn-rwx-segments`
- **效果**：兼容新版 ARM GCC (15.x) 链接器

## 四、协议升级：HID v1 → WinUSB v2

| 特性 | CMSIS-DAP v1 (HID) | CMSIS-DAP v2 (WinUSB/Bulk) |
|---|---|---|
| USB 驱动 | HID 免驱 | Win10+ WinUSB 免驱 |
| 传输方式 | 中断传输 (1ms 轮询) | 批量传输 (背靠背) |
| 理论带宽 | ~64 KB/s | ~1.2 MB/s |
| 实际烧录速度 | ~8-12 KB/s | ~30-50 KB/s |

## 五、Flash 分区布局

| 地址范围 | 分区 | 大小 |
| --- | --- | --- |
| `0x08000000 ~ 0x0800BFFF` | BL | 48KB |
| `0x0800C000 ~ 0x0801FBFF` | IF | 79KB（+CRC 4B） |
| `0x0801FC00 ~ 0x0801FFFF` | Config | 1KB |
| **合计** | | **128KB** |

## 六、烧录方法

**务必先全片擦除，再按顺序烧录：**

```bash
# 1. SWD 全片擦除 (Chip Erase)
# 2. SWD 烧录 BL
pyocd flash -t stm32f103xb bl_crc.hex
# 3. USB 连接 → MAINTENANCE 模式
# 4. 拖入 IF CRC hex → DAPLink 模式
# 5. USB 拔插 → 仍保持 DAPLink
```

## 七、固件输出路径

- **BL**：`projectfiles/make_gcc_arm/stm32f103xb_bl/build/stm32f103xb_bl_crc.hex`
- **IF**：`projectfiles/make_gcc_arm/stm32f103xb_stm32f103rb_if/build/stm32f103xb_stm32f103rb_if_crc.hex`

## 八、编译方法

```powershell
# 方法1：一键编译
cd apm32-daplink
.\build_apm32f103cb.ps1

# 方法2：手动编译
cd projectfiles/make_gcc_arm/stm32f103xb_bl && make clean && make -j4
cd ../stm32f103xb_stm32f103rb_if && make clean && make -j4
```

---

*创建时间：2026-07-20*  
*最后更新：2026-07-26*
