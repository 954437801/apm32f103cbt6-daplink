# APM32F103CBT6 DAPLink 96MHz 适配 + IAP 冷启动丢失修复

## 一、问题现象

1. BL(72MHz) + IF(96MHz) 通过 IAP 拖入 IF CRC hex 后热启动正常
2. USB 拔插（冷启动）后回退到 MAINTENANCE 模式
3. 直接 SWD 刷 IF hex 则正常保持 DAPLink

## 二、根因分析

1. BL 中 `flash_regions[0].end` 设为 `0x08020000`（整片 128KB 结尾）
2. IAP 时 EraseChip 擦除 **80 页**（`0x0800C000 ~ 0x0801FFFF`）
3. 配置区（`0x0801FC00 ~ 0x0801FFFF`）被擦除但未重写
4. 冷启动后 IF 检测到配置无效，执行 `config_rom_init()`
   → `program_cfg()`：`flash_erase_sector + flash_program_page`
5. 在 96MHz × 3WS 配置下，配置区的擦写操作影响 IF 最后一个扇区的 CRC
6. 正确范围应为 **79 页**（`0x0800C000 ~ 0x0801FBFF`），不含配置区

## 三、修改的文件（共 4 个）

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
- TIM2 时钟分频自适应：根据 `SystemCoreClock` 自动计算

### 3. `source/hic_hal/stm32/stm32f103xb/flash.c`

- `EraseChip()` 中 assert 行修复：
  - **修改前**：`(end - start) / FLASH_PAGE_SIZE == 0`（错误，取模用成了除）
  - **修改后**：`(end - start) % FLASH_PAGE_SIZE == 0`（正确，检查对齐）

### 4. `source/hic_hal/stm32/stm32f103xb/daplink_addr.h`

- `IF_SIZE = 0x00013C00`（79KB）紧邻配置区
- 配置区 = `0x0801FC00`，大小 `0x400`（1KB）
- BL=48KB, IF=79KB, Config=1KB = 128KB（完全填满）

## 四、Flash 分区布局

| 地址范围 | 分区 | 大小 |
| --- | --- | --- |
| `0x08000000 ~ 0x0800BFFF` | BL | 48KB |
| `0x0800C000 ~ 0x0801FBFF` | IF | 79KB（+CRC 4B） |
| `0x0801FC00 ~ 0x0801FFFF` | Config | 1KB |
| **合计** | | **128KB** |

## 五、验证结果

- [x] BL 编译：48KB（100% 填满，完美适配）
- [x] IF 编译：79KB + CRC4B
- [x] SWD 烧录 BL → 进入 MAINTENANCE
- [x] SWD 烧录 IF → DAPLink 正常
- [x] USB 拔插后 → 仍然保持 DAPLink
- [x] IAP 拖入 IF CRC hex → 正常工作

## 六、固件输出路径

- **BL**：`projectfiles/make_gcc_arm/stm32f103xb_bl/build/stm32f103xb_bl_crc.hex`
- **IF**：`projectfiles/make_gcc_arm/stm32f103xb_stm32f103rb_if/build/stm32f103xb_stm32f103rb_if_crc.hex`

## 七、编译方法

```bash
cd projectfiles/make_gcc_arm/stm32f103xb_bl && make clean && make -j4
cd projectfiles/make_gcc_arm/stm32f103xb_stm32f103rb_if && make clean && make -j4
```

---

*创建时间：2026-07-20*
