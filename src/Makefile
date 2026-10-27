KDIR ?= /lib/modules/$(shell uname -r)/build
obj-m += saa7231_core.o
saa7231_core-y := saa7231_pci.o saa7231_cgu.o saa7231_i2c.o saa7231_if.o \
                  saa7231_msi.o saa7231_dmabuf.o saa7231_gpio.o saa7231_ring.o \
                  saa7231_ts2dtl.o saa7231_xs2dtl.o saa7231_stream.o \
                  saa7231_dvb.o saa7231_vfl.o saa7231_audio.o
ccflags-y += -I$(src) -I$(KDIR)/drivers/media/dvb-core -I$(KDIR)/include/media -I$(KDIR)/drivers/media/dvb-frontends -I$(KDIR)/drivers/media/tuners
all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
obj-m += saa7231_drv.o
obj-m += tda18273.o
