# 顶层 Makefile
KDIR := /home/czd/kernel-dev/linux-6.19.8

# 所有包含内核模块的子目录
SUBDIRS := hello-1

all:
	@for dir in $(SUBDIRS); do \
		$(MAKE) -C $$dir KDIR=$(KDIR); \
	done

clean:
	@for dir in $(SUBDIRS); do \
		$(MAKE) -C $$dir KDIR=$(KDIR) clean; \
	done