# 子目录 Makefile
obj-m += $(notdir $(CURDIR)).o

# KDIR 由顶层 Makefile 传入，如果未传入则给出默认值
KDIR ?= /home/czd/kernel-dev/linux-6.19.8

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean