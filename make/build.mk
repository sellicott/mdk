PROG        ?= firmware
MDK         ?= $(realpath $(dir $(lastword $(MAKEFILE_LIST)))/..)
ARCH        ?= ESP32C3
TOOLCHAIN   ?= riscv64-elf 
OBJ_PATH    = ./build
ESPUTIL     ?= $(MDK)/tools/esputil
ESPTOOL     ?= python -m esptool
PORT        ?= /dev/ttyUSB0
flash_mode  = 021f
chip_id     = 05
chip_rev    = 02

# SDE: Hacks to try and get tcc working with an override script
CC          ?= $(TOOLCHAIN)-gcc
RISC-LD     ?= $(TOOLCHAIN)-gcc
CXX         ?= $(TOOLCHAIN)-g++
OBJCOPY     ?= $(TOOLCHAIN)-objcopy
SIZE        ?= $(TOOLCHAIN)-size
#TCC_INCLUDE ?= /usr/riscv64-elf/include
TCC_INCLUDE ?= /home/nebk/Documents/programs/risc-v/tcc-riscv32/include 

# -g3 pulls enums and defines into the debug info for GDB
# -ffunction-sections -fdata-sections, -Wl,--gc-sections remove unused code
# strict WARNFLAGS protect from stupid mistakes

ifeq "$(ARCH)" "ESP32C3"
MCUFLAGS  ?= -march=rv32im -mabi=ilp32
WARNFLAGS ?= -Wformat-truncation
BLOFFSET  ?= 0  # 2nd stage bootloader flash offset
else 
MCUFLAGS  ?= -mlongcalls -mtext-section-literals
BLOFFSET  ?= 0x1000  # 2nd stage bootloader flash offset
endif

DEFS      ?=
INCLUDES  ?= -I. -I$(MDK)/src -I$(TCC_INCLUDE) -D$(ARCH)
WARNFLAGS ?= -W -Wall -Wextra -Wundef -Wshadow -Wdouble-promotion -fno-common -Wconversion
OPTFLAGS  ?= -Os -g -ffunction-sections -fdata-sections
CFLAGS    ?= $(WARNFLAGS) $(OPTFLAGS) $(MCUFLAGS) $(INCLUDES) $(DEFS) $(EXTRA_CFLAGS)
#CFLAGS    ?= $(INCLUDES) $(DEFS) $(EXTRA_CFLAGS)
LINKFLAGS ?= $(MCUFLAGS) -T$(MDK)/make/$(ARCH).ld -nostdlib -nostartfiles -Wl,--gc-sections $(EXTRA_LINKFLAGS)


define edit_bin
sed "1s/^\(.\{4\}\).\{4\}/\1$(flash_mode)/; \
     1s/^\(.\{24\}\).\{2\}/\1$(chip_id)/; \
     1s/^\(.\{28\}\).\{2\}/\1$(chip_rev)/" -
endef

SOURCES += $(MDK)/src/boot/boot_$(ARCH).s
SOURCES += $(wildcard $(MDK)/src/*.c)
HEADERS += $(wildcard $(MDK)/src/*.h)
_BJECTS = $(SOURCES:%.c=$(OBJ_PATH)/%.o)
OBJECTS = $(_BJECTS:%.cpp=$(OBJ_PATH)/%.o)

build: $(OBJ_PATH)/$(PROG).bin
$(OBJECTS): $(HEADERS)

unix: MCUFLAGS =
unix: OPTFLAGS = -O0 -g3
unix: SRCS = $(filter-out %.s,$(filter-out $(MDK)/src/malloc.c,$(SOURCES)))
unix: $(SRCS)
	@mkdir -p $(OBJ_PATH)
	$(CC) $(CFLAGS) $(SRCS) -o $(OBJ_PATH)/firmware

$(OBJ_PATH)/%.o: %.c $(wildcard $(MDK)/include/%.h)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(OBJ_PATH)/%.o: %.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CFLAGS) -c $< -o $@

$(OBJ_PATH)/%.o: %.s
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(OBJ_PATH)/$(PROG).elf: $(OBJECTS)
	$(RISC-LD) -Xlinker $(OBJECTS) $(LINKFLAGS) -o $@
	$(SIZE) $@

# elf_section_load_address FILE,SECTION_NAME
elf_section_load_address = $(shell $(TOOLCHAIN)-objdump -h $1 | grep $2 | tr -s ' ' | cut -d ' ' -f 5)

# elf_symbol_address FILE,SYMBOL
elf_entry_point_address = $(shell $(TOOLCHAIN)-nm $1 | grep 'T $2' | cut -f1 -dT)

$(OBJ_PATH)/$(PROG).bin: $(ESPUTIL)
$(OBJ_PATH)/$(PROG).bin: $(OBJ_PATH)/$(PROG).elf
	$(OBJCOPY) -O binary --only-section .text $< $(OBJ_PATH)/.text.bin
	$(OBJCOPY) -O binary --only-section .data $< $(OBJ_PATH)/.data.bin
	$(ESPUTIL) mkbin $@ $(call elf_entry_point_address,$<,_reset) $(call elf_section_load_address,$<,.data) $(OBJ_PATH)/.data.bin $(call elf_section_load_address,$<,.text) $(OBJ_PATH)/.text.bin

$(OBJ_PATH)/$(PROG)_edit.bin: $(OBJ_PATH)/$(PROG).bin
	xxd -p $< | $(edit_bin) | xxd -p -r - > $@

flash: $(OBJ_PATH)/$(PROG).bin $(ESPUTIL)
	$(ESPUTIL) flash $(BLOFFSET) $(OBJ_PATH)/$(PROG).bin

esptool: $(OBJ_PATH)/$(PROG)_edit.bin
	$(ESPTOOL) -p $(PORT) write_flash $(BLOFFSET) $< 

monitor: $(ESPUTIL)
	$(ESPUTIL) monitor

$(ESPUTIL): $(MDK)/tools/esputil.c
	make -C $(MDK)/tools esputil

clean:
	@rm -rf *.{bin,elf,map,lst,tgz,zip,hex} $(OBJ_PATH)
