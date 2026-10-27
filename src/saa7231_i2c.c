/*
 *	SAA7231xx PCI/PCI Express bridge driver
 *
 *	Copyright (C) Manu Abraham <abraham.manu@gmail.com>
 *
 *	This program is free software; you can redistribute it and/or modify
 *	it under the terms of the GNU General Public License as published by
 *	the Free Software Foundation; either version 2 of the License, or
 *	(at your option) any later version.
 *
 *	This program is distributed in the hope that it will be useful,
 *	but WITHOUT ANY WARRANTY; without even the implied warranty of
 *	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *	GNU General Public License for more details.
 *
 *	You should have received a copy of the GNU General Public License
 *	along with this program; if not, write to the Free Software
 *	Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 */

#include <linux/kernel.h>
#include <linux/pci.h>
#include <linux/delay.h>
#include <linux/module.h>
#include <linux/io.h>
#include <linux/string.h>

#include <asm/irq.h>
#include <linux/signal.h>
#include <linux/sched.h>
#include <linux/interrupt.h>
#include <linux/mutex.h>
#include <linux/i2c.h>

#include "saa7231_priv.h"
#include "saa7231_mod.h"
#include "saa7231_cgu.h"
#include "saa7231_i2c_reg.h"
#include "saa7231_msi.h"
#include "saa7231_i2c.h"


#define SAA7231_I2C_ADAPTERS			4

/*
 * Register-level protocol reverse engineered from the vendor
 * Windows driver (saa7231.sys).  The I2C block is word driven:
 * every word pushed into TX_FIFO is either a command word carrying
 * START/STOP flags and an address, or a data byte.
 *
 * Status/interrupt bits (same meaning as the vendor driver uses):
 *	I2C_STATUS bit 11	TX FIFO blocked
 *	I2C_STATUS bit  7	TX FIFO full
 *	I2C_STATUS bit  6	TX FIFO empty
 *	I2C_STATUS bit 10	RX FIFO blocked
 *	I2C_STATUS bit  4	RX FIFO empty
 *	I2C_STATUS bits 2,3	SCL, SDA line level
 *	INT_STATUS bits 1,2,6	transfer error (NACK/arbitration loss)
 *	INT_STATUS bit  0	transfer done
 */
#define SAA7231_I2C_CTL_IDLE		0x00c0
#define SAA7231_I2C_CTL_INIT		0x00cd
#define SAA7231_I2C_CTL_SCL_LOW		0x0040

#define SAA7231_I2C_START		(1 << 8)
#define SAA7231_I2C_STOP		(1 << 9)

#define SAA7231_I2C_INT_DONE_MASK	0x00c7
#define SAA7231_I2C_INT_ERR_MASK	0x0046

#define SAA7231_I2C_TXBUSY	(TX_FIFO_BLOCK	| TX_FIFO_FULL)

/*
 * Experiment selector for the TX FIFO word encoding of data phases.
 *   0: original, STOP OR-ed into the last data byte
 *   1: last data byte sent plain, STOP queued as its own 0x200 word
 *   2: data bytes shifted left by one, STOP OR-ed into last
 *   3: data bytes shifted left by one, STOP as its own word
 */
static int xfer_mode;
module_param(xfer_mode, int, 0644);
MODULE_PARM_DESC(xfer_mode, "I2C TX word encoding experiment (0-3)");

/*
 * Bring-up knobs, all matching what the vendor binary does when set
 * to 0/1 as noted.  Defaults preserve the previous behaviour so that a
 * plain modprobe changes nothing.
 */
static int per_xfer_reset = 1;
module_param(per_xfer_reset, int, 0644);
MODULE_PARM_DESC(per_xfer_reset,
	"1: reset the I2C block before every transfer (default); "
	"0: vendor behaviour, reset only when STATUS low byte != 0x5d");

static int ctrl_bit0;
module_param(ctrl_bit0, int, 0644);
MODULE_PARM_DESC(ctrl_bit0, "OR 0x01 into I2C_CONTROL before each transfer");

static int clk_hi, clk_lo, clk_hold;
module_param(clk_hi, int, 0644);
module_param(clk_lo, int, 0644);
module_param(clk_hold, int, 0644);
MODULE_PARM_DESC(clk_hi, "Override I2C_CLOCK_DIVISOR_HIGH (0 = use table)");
MODULE_PARM_DESC(clk_lo, "Override I2C_CLOCK_DIVISOR_LOW (0 = use table)");
MODULE_PARM_DESC(clk_hold, "Override I2C_SDA_HOLD (0 = use table)");

static int write_no_stop;
module_param(write_no_stop, int, 0644);
MODULE_PARM_DESC(write_no_stop,
	"1: vendor-exact write phase - no STOP word and no completion wait");

static int dump_words;
module_param(dump_words, int, 0644);
MODULE_PARM_DESC(dump_words, "Log every word pushed into the TX FIFO");

/*
 * Bring-up debugger: write "offset" or "offset:value" to this parameter to
 * read or write one 32-bit BAR0 register of the first SAA7231 in the system.
 * Offsets and values may be decimal or 0x-prefixed.
 */
static int dbg_mmio_bar(int bar, const char *val)
{
	struct pci_dev *pdev;
	void __iomem *io;
	unsigned int off, w;
	int have_val;
	u32 r;

	have_val = sscanf(val, "%i:%i", &off, &w) == 2;
	if (!have_val && sscanf(val, "%i", &off) != 1)
		return -EINVAL;

	pdev = pci_get_device(0x1131, 0x7231, NULL);
	if (!pdev)
		return -ENODEV;
	if ((unsigned long)off + 4 > pci_resource_len(pdev, bar)) {
		pci_dev_put(pdev);
		return -EINVAL;
	}
	io = ioremap(pci_resource_start(pdev, bar),
		     pci_resource_len(pdev, bar));
	if (io) {
		if (have_val) {
			writel(w, io + off);
			r = readl(io + off);
			pr_info("saa7231 dbg_mmio bar%u: [%#x] <- %#x (read %#x)\n",
				bar, off, w, r);
		} else {
			r = readl(io + off);
			pr_info("saa7231 dbg_mmio bar%u: [%#x] = %#x\n",
				bar, off, r);
		}
		iounmap(io);
	}
	pci_dev_put(pdev);
	return io ? 0 : -ENOMEM;
}

static int dbg_mmio_set(const char *val, const struct kernel_param *kp)
{
	return dbg_mmio_bar(BAR_0, val);
}

static int dbg_mmio2_set(const char *val, const struct kernel_param *kp)
{
	return dbg_mmio_bar(BAR_2, val);
}

static const struct kernel_param_ops dbg_mmio_ops = {
	.set = dbg_mmio_set,
};
static const struct kernel_param_ops dbg_mmio2_ops = {
	.set = dbg_mmio2_set,
};

module_param_cb(dbg_mmio, &dbg_mmio_ops, NULL, 0644);
MODULE_PARM_DESC(dbg_mmio, "Read/write a BAR0 register: \"offset[:value]\"");
module_param_cb(dbg_mmio2, &dbg_mmio2_ops, NULL, 0644);
MODULE_PARM_DESC(dbg_mmio2, "Read/write a BAR2 register: \"offset[:value]\"");

/*
 * Analog bring-up: activates the video clock use case, then reads/writes a
 * BAR0 register (absolute offset, e.g. 0x20239c).  "clock" only activates.
 */
static int dbg_avis_set(const char *val, const struct kernel_param *kp)
{
	struct pci_dev *pdev;
	struct saa7231_dev *saa7231;
	int ret;

	if (sysfs_streq(val, "clock")) {
		pdev = pci_get_device(0x1131, 0x7231, NULL);
		if (!pdev)
			return -ENODEV;
		saa7231 = pci_get_drvdata(pdev);
		if (!saa7231) {
			pci_dev_put(pdev);
			return -ENODEV;
		}
		ret = saa7231_activate_clocks(saa7231, VIDEO_CAPTURE,
					      STREAM_PORT_VS2D_AVIS);
		pr_info("saa7231 dbg_avis: video clocks, ret=%d\n", ret);
		pci_dev_put(pdev);
		return ret;
	}
	return dbg_mmio_bar(BAR_0, val);
}

static const struct kernel_param_ops dbg_avis_ops = {
	.set = dbg_avis_set,
};

module_param_cb(dbg_avis, &dbg_avis_ops, NULL, 0644);
MODULE_PARM_DESC(dbg_avis,
	"Analog AVIS: \"clock\" or BAR0 read/write \"offset[:value]\" (absolute)");

/* "offset:words" - dump a BAR0 range to dmesg, 8 words per line */
static int dbg_dump_set(const char *val, const struct kernel_param *kp)
{
	struct pci_dev *pdev;
	void __iomem *io;
	unsigned int off, len, i, n, bar = BAR_0;
	char buf[80];

	if (sscanf(val, "%i:%i:%i", &bar, &off, &len) != 3) {
		bar = BAR_0;
		if (sscanf(val, "%i:%i", &off, &len) != 2)
			return -EINVAL;
	}
	if ((bar != BAR_0 && bar != BAR_2) || !len || len > 8192)
		return -EINVAL;

	pdev = pci_get_device(0x1131, 0x7231, NULL);
	if (!pdev)
		return -ENODEV;
	/* reading past the mapped BAR is a kernel fault, not an error */
	if ((unsigned long)off + 4UL * len > pci_resource_len(pdev, bar)) {
		pci_dev_put(pdev);
		return -EINVAL;
	}
	io = ioremap(pci_resource_start(pdev, bar),
		     pci_resource_len(pdev, bar));
	if (!io) {
		pci_dev_put(pdev);
		return -ENOMEM;
	}

	while (len) {
		n = len > 8 ? 8 : len;
		buf[0] = '\0';
		for (i = 0; i < n; i++)
			scnprintf(buf + strlen(buf), sizeof(buf) - strlen(buf),
				  " %08x", readl(io + off + 4 * i));
		pr_info("saa7231 dbg_dump bar%u %#08x:%s\n", bar, off, buf);
		off += 4 * n;
		len -= n;
	}

	iounmap(io);
	pci_dev_put(pdev);
	return 0;
}

static const struct kernel_param_ops dbg_dump_ops = {
	.set = dbg_dump_set,
};

module_param_cb(dbg_dump, &dbg_dump_ops, NULL, 0644);
MODULE_PARM_DESC(dbg_dump, "Dump a BAR0 range: \"offset:words\"");


static const char *adap_name[] = {
	"SAA7231 I2C:0",
	"SAA7231 12C:1",
	"SAA7231 I2C:2",
	"SAA7231 I2C:3"
};

static const u32 i2c_dev[] = {
	I2C0,
	I2C1,
	I2C2,
	I2C3
};

#define SAA7231_I2C_BUS(__x) (i2c_dev[__x])

#define SAA7231_I2C_ADAPTER_NAME(__dev)		\
	(adap_name[__dev])

#define SAA7231_I2C_ADAP(__dev)			\
	(i2c_dev[__dev])

/*
 * Clock divisors exactly as the vendor driver programs them.
 * (hi, lo, sda_hold) - the vendor uses these two sets only.
 */
static void saa7231_i2c_setclock(struct saa7231_i2c *i2c, u32 I2C_DEV)
{
	struct saa7231_dev *saa7231 = i2c->saa7231;
	u32 hi, lo, hold;

	switch (i2c->i2c_rate) {
	case SAA7231_I2C_RATE_100:
		hi = 0x00d0; lo = 0x010e; hold = 0x0043;
		break;
	case SAA7231_I2C_RATE_400:
	default:
		hi = 0x0034; lo = 0x0044; hold = 0x0011;
		break;
	}

	if (clk_hi || clk_lo || clk_hold) {
		hi = clk_hi;
		lo = clk_lo;
		hold = clk_hold;
	}

	SAA7231_WR(hi,   SAA7231_BAR0, I2C_DEV, I2C_CLOCK_DIVISOR_HIGH);
	SAA7231_WR(lo,   SAA7231_BAR0, I2C_DEV, I2C_CLOCK_DIVISOR_LOW);
	SAA7231_WR(hold, SAA7231_BAR0, I2C_DEV, I2C_SDA_HOLD);
}

/*
 * Port of the vendor "I2C module reset" helper:
 *  - drop the block into its reset state and wait for it to settle,
 *  - if SDA is held low by a wedged slave, clock SCL nine times,
 *  - verify that the bus came back to the idle state.
 */
static int saa7231_i2c_reset(struct saa7231_i2c *i2c, u32 I2C_DEV)
{
	struct saa7231_dev *saa7231 = i2c->saa7231;
	int i;
	u32 reg;

	SAA7231_WR(SAA7231_I2C_CTL_INIT, SAA7231_BAR0, I2C_DEV, I2C_CONTROL);

	for (i = 0; i < 100; i++) {
		reg = SAA7231_RD(SAA7231_BAR0, I2C_DEV, I2C_CONTROL);
		if ((reg & 0xff) == SAA7231_I2C_CTL_IDLE)
			break;
		udelay(1);
	}
	if (i == 100) {
		dprintk(SAA7231_ERROR, 1,
			"dev=%x: control did not settle (ctrl=%08x)",
			I2C_DEV, reg);
		return -EIO;
	}

	reg = SAA7231_RD(SAA7231_BAR0, I2C_DEV, I2C_STATUS);
	if (!(reg & SDA)) {
		/* SDA stuck low - free the slave with 9 SCL pulses */
		dprintk(SAA7231_ERROR, 1,
			"dev=%x: SDA stuck low (status=%08x), clocking bus free",
			I2C_DEV, reg);
		for (i = 0; i < 9; i++) {
			SAA7231_WR(SAA7231_I2C_CTL_SCL_LOW, SAA7231_BAR0,
				   I2C_DEV, I2C_CONTROL);
			udelay(10);
			SAA7231_WR(SAA7231_I2C_CTL_IDLE, SAA7231_BAR0,
				   I2C_DEV, I2C_CONTROL);
			udelay(10);
		}
	}

	reg = SAA7231_RD(SAA7231_BAR0, I2C_DEV, I2C_STATUS);
	if ((reg & 0x0f) != 0x0d)
		dprintk(SAA7231_ERROR, 1,
			"dev=%x: bus not idle after reset (status=%08x)",
			I2C_DEV, reg);

	/* clear any stale interrupt state */
	SAA7231_WR(0x1fff, SAA7231_BAR0, I2C_DEV, INT_CLR_STATUS);

	return 0;
}

static int saa7231_i2c_hwinit(struct saa7231_i2c *i2c, u32 I2C_DEV)
{
	struct saa7231_dev *saa7231 = i2c->saa7231;
	struct i2c_adapter *adapter = &i2c->i2c_adapter;
	int err;

	err = saa7231_i2c_reset(i2c, I2C_DEV);
	if (err < 0) {
		dprintk(SAA7231_ERROR, 1, "Adapter (%02x) %s RESET failed",
			I2C_DEV, adapter->name);
		return err;
	}

	saa7231_i2c_setclock(i2c, I2C_DEV);

	SAA7231_WR(0x1fff, SAA7231_BAR0, I2C_DEV, INT_CLR_ENABLE);
	SAA7231_WR(0x1fff, SAA7231_BAR0, I2C_DEV, INT_CLR_STATUS);

	dprintk(SAA7231_ERROR, 1,
		"DBG init dev=%x status=%08x ctrl=%08x clkhi=%08x clklo=%08x hold=%08x modconf=%08x modid=%08x",
		I2C_DEV,
		SAA7231_RD(SAA7231_BAR0, I2C_DEV, I2C_STATUS),
		SAA7231_RD(SAA7231_BAR0, I2C_DEV, I2C_CONTROL),
		SAA7231_RD(SAA7231_BAR0, I2C_DEV, I2C_CLOCK_DIVISOR_HIGH),
		SAA7231_RD(SAA7231_BAR0, I2C_DEV, I2C_CLOCK_DIVISOR_LOW),
		SAA7231_RD(SAA7231_BAR0, I2C_DEV, I2C_SDA_HOLD),
		SAA7231_RD(SAA7231_BAR0, I2C_DEV, MODULE_CONF),
		SAA7231_RD(SAA7231_BAR0, I2C_DEV, MODULE_ID));

	return 0;
}

/*
 * Queue one word for the I2C engine.  Only the "FIFO full/blocked"
 * condition is waited for - exactly like the vendor driver, which
 * does not wait for the FIFO to drain here.
 */
static int saa7231_i2c_push(struct saa7231_i2c *i2c, u32 I2C_DEV, u32 word)
{
	struct saa7231_dev *saa7231 = i2c->saa7231;
	int i;
	u32 reg;

	for (i = 0; i < 10000; i++) {
		reg = SAA7231_RD(SAA7231_BAR0, I2C_DEV, I2C_STATUS);
		if (!(reg & SAA7231_I2C_TXBUSY)) {
			SAA7231_WR(word, SAA7231_BAR0, I2C_DEV, TX_FIFO);
			if (dump_words)
				dprintk(SAA7231_ERROR, 1,
					"DBG push dev=%x word=%04x",
					I2C_DEV, word);
			return 0;
		}
		udelay(8);
	}

	dprintk(SAA7231_ERROR, 1,
		"dev=%x: TX FIFO stuck (word=%04x status=%08x)",
		I2C_DEV, word, reg);

	return -EIO;
}

/* Wait for TX FIFO to drain (used before fetching a received byte). */
static int saa7231_i2c_wait_tx(struct saa7231_i2c *i2c, u32 I2C_DEV)
{
	struct saa7231_dev *saa7231 = i2c->saa7231;
	int i;
	u32 reg = 0;

	for (i = 0; i < 20000; i++) {
		reg = SAA7231_RD(SAA7231_BAR0, I2C_DEV, I2C_STATUS);
		if (reg & TX_FIFO_EMPTY)
			return 0;
		udelay(8);
	}

	dprintk(SAA7231_ERROR, 1,
		"dev=%x: TX FIFO not empty after timeout, status=%08x",
		I2C_DEV, reg);

	return -EIO;
}

/*
 * Wait for a transfer event and report whether it was an error
 * (NACK / arbitration lost).  Returns -ENXIO on a NAK so that
 * i2c core users (and i2cdetect) see the standard "no device".
 */
static int saa7231_i2c_wait_int(struct saa7231_i2c *i2c, u32 I2C_DEV)
{
	struct saa7231_dev *saa7231 = i2c->saa7231;
	int i;
	u32 reg = 0;

	for (i = 0; i < 10000; i++) {
		reg = SAA7231_RD(SAA7231_BAR0, I2C_DEV, INT_STATUS);
		if (reg & SAA7231_I2C_INT_DONE_MASK)
			break;
		udelay(8);
	}
	if (i == 10000) {
		dprintk(SAA7231_ERROR, 1,
			"dev=%x: no I2C interrupt (isr=%08x status=%08x)",
			I2C_DEV, reg,
			SAA7231_RD(SAA7231_BAR0, I2C_DEV, I2C_STATUS));
		return -EIO;
	}

	SAA7231_WR(reg, SAA7231_BAR0, I2C_DEV, INT_CLR_STATUS);

	if (reg & SAA7231_I2C_INT_ERR_MASK) {
		dprintk(SAA7231_ERROR, 1,
			"dev=%x: I2C error irq=0x%02x status=%08x",
			I2C_DEV, reg & 0xff,
			SAA7231_RD(SAA7231_BAR0, I2C_DEV, I2C_STATUS));
		return -ENXIO;
	}

	return 0;
}

/*
 * Completion wait used at the end of a read phase. The vendor masks
 * with 0x47 here (bit 0 = done, bits 1/2/6 = error/TX empty), not 0xc7.
 */
static int saa7231_i2c_wait_read_int(struct saa7231_i2c *i2c, u32 I2C_DEV)
{
	struct saa7231_dev *saa7231 = i2c->saa7231;
	int i;
	u32 reg = 0;

	for (i = 0; i < 10000; i++) {
		reg = SAA7231_RD(SAA7231_BAR0, I2C_DEV, INT_STATUS);
		if (reg & 0x47)
			break;
		udelay(8);
	}
	if (i == 10000)
		return -EIO;

	SAA7231_WR(reg, SAA7231_BAR0, I2C_DEV, INT_CLR_STATUS);

	if (reg & SAA7231_I2C_INT_ERR_MASK)
		return -ENXIO;

	return 0;
}

static int saa7231_i2c_read_byte(struct saa7231_i2c *i2c, u32 I2C_DEV, u32 *data)
{
	struct saa7231_dev *saa7231 = i2c->saa7231;
	int i;
	u32 reg = 0;

	for (i = 0; i < 20000; i++) {
		reg = SAA7231_RD(SAA7231_BAR0, I2C_DEV, I2C_STATUS);
		if (!(reg & (RX_FIFO_BLOCK | RX_FIFO_EMPTY))) {
			u32 raw = SAA7231_RD(SAA7231_BAR0, I2C_DEV, RX_FIFO);
			dprintk(SAA7231_ERROR, 1,
				"DBG dev=%x RX raw=%08x status=%08x",
				I2C_DEV, raw, reg);
			*data = raw & 0xff;
			return 0;
		}
		udelay(8);
	}

	dprintk(SAA7231_ERROR, 1,
		"dev=%x: RX FIFO empty after timeout, status=%08x",
		I2C_DEV, reg);

	return -EIO;
}

static int saa7231_i2c_xfer(struct i2c_adapter *adapter, struct i2c_msg *msgs, int num)
{
	struct saa7231_i2c *i2c		= i2c_get_adapdata(adapter);
	struct saa7231_dev *saa7231	= i2c->saa7231;

	u32 DEV = SAA7231_I2C_BUS(i2c->i2c_dev);
	int i, j, err = 0;
	u32 data;

	dprintk(SAA7231_DEBUG, 0, "\n");
	dprintk(SAA7231_DEBUG, 1, "Bus(%02x) I2C transfer", DEV);
	mutex_lock(&i2c->i2c_lock);

	/*
	 * The vendor pre-transfer helper (0x205f4) reads I2C_STATUS and
	 * resets the block only when the low byte is not 0x5d, i.e. when
	 * the bus was left busy by the previous transaction.  An idle bus
	 * (0x15d) is used as is.
	 */
	if (per_xfer_reset) {
		err = saa7231_i2c_reset(i2c, DEV);
		if (err < 0)
			goto fail;
		saa7231_i2c_setclock(i2c, DEV);
	} else {
		u32 st = SAA7231_RD(SAA7231_BAR0, DEV, I2C_STATUS);

		if ((st & 0xff) != 0x5d) {
			dprintk(SAA7231_ERROR, 1,
				"DBG pre-xfer reset, status=%08x", st);
			err = saa7231_i2c_reset(i2c, DEV);
			if (err < 0)
				goto fail;
			saa7231_i2c_setclock(i2c, DEV);
		}
	}

	if (ctrl_bit0) {
		u32 c = SAA7231_RD(SAA7231_BAR0, DEV, I2C_CONTROL);

		SAA7231_WR(c | 0x01, SAA7231_BAR0, DEV, I2C_CONTROL);
	}

	for (i = 0; i < num; i++) {

		u32 addr = (msgs[i].addr << 1) |
			   (msgs[i].flags & I2C_M_RD ? 1 : 0);

		dprintk(SAA7231_DEBUG, 0, "\n    len=%d <ST> <%02x> %s",
			msgs[i].len, addr,
			(msgs[i].flags & I2C_M_RD) ? "<R> " : "<W> ");

		if (msgs[i].len == 0) {
			/* address-only transaction */
			err = saa7231_i2c_push(i2c, DEV,
					       addr | SAA7231_I2C_START |
					       SAA7231_I2C_STOP);
			if (err < 0)
				goto fail;
			err = saa7231_i2c_wait_int(i2c, DEV);
			if (err < 0)
				goto fail;
			continue;
		}

		/* start condition + slave address, then wait for its ACK */
		err = saa7231_i2c_push(i2c, DEV, addr | SAA7231_I2C_START);
		if (err < 0)
			goto fail;

		/*
		 * The vendor engine does not wait for the address-phase
		 * interrupt on a read that follows a write (the repeated
		 * start); the ACK is folded into the final completion wait.
		 */
		if ((msgs[i].flags & I2C_M_RD) && i > 0) {
			/* no wait here */
		} else {
			err = saa7231_i2c_wait_int(i2c, DEV);
			if (err < 0) {
				dprintk(SAA7231_ERROR, 1,
					"Bus(%02x) no ACK from address 0x%02x",
					DEV, msgs[i].addr);
				goto fail;
			}
		}

		if (!(msgs[i].flags & I2C_M_RD)) {
			for (j = 0; j < msgs[i].len; j++) {
				int last = (i == (num - 1) &&
					    j == (msgs[i].len - 1));

				data = msgs[i].buf[j];
				if (xfer_mode & 2)
					data <<= 1;

				dprintk(SAA7231_DEBUG, 0, "<%02x> ", (data & 0xff));

				if (write_no_stop)
					err = saa7231_i2c_push(i2c, DEV, data);
				else if (xfer_mode & 1) {
					err = saa7231_i2c_push(i2c, DEV, data);
					if (!err && last)
						err = saa7231_i2c_push(i2c, DEV,
								       SAA7231_I2C_STOP);
				} else {
					if (last)
						data |= SAA7231_I2C_STOP;
					err = saa7231_i2c_push(i2c, DEV, data);
				}
				if (err < 0)
					goto fail;
			}
			/*
			 * Only the last message of the transaction carries
			 * a STOP and therefore produces a completion
			 * interrupt; intermediate messages are just queued.
			 * The vendor's pure-write path (0x208c0 with no read
			 * phase) pushes the bytes and returns without any
			 * STOP or completion wait at all.
			 */
			if (i == (num - 1) && !write_no_stop) {
				err = saa7231_i2c_wait_int(i2c, DEV);
				if (err < 0)
					goto fail;
			}

		} else {
			for (j = 0; j < msgs[i].len; j++) {
				data = 0;
				if (j == (msgs[i].len - 1))
					data |= SAA7231_I2C_STOP;

				err = saa7231_i2c_push(i2c, DEV, data);
				if (err < 0)
					goto fail;

				err = saa7231_i2c_wait_tx(i2c, DEV);
				if (err < 0)
					goto fail;

				err = saa7231_i2c_read_byte(i2c, DEV, &data);
				if (err < 0)
					goto fail;

				msgs[i].buf[j] = data & 0xff;
				dprintk(SAA7231_DEBUG, 0, " <R=%02x>", data & 0xff);
			}
			/* final STOP / NACK check */
			err = saa7231_i2c_wait_read_int(i2c, DEV);
			if (err < 0)
				goto fail;
		}
	}

	err = num;

fail:
	if (err < 0) {
		dprintk(SAA7231_ERROR, 1, "ERROR: Bailing out <%d>", err);
		saa7231_i2c_reset(i2c, DEV);
		saa7231_i2c_setclock(i2c, DEV);
	}
	mutex_unlock(&i2c->i2c_lock);
	return err;
}

static u32 saa7231_i2c_func(struct i2c_adapter *adapter)
{
	return I2C_FUNC_I2C | I2C_FUNC_SMBUS_EMUL;
}

static const struct i2c_algorithm saa7231_algo = {
	.master_xfer	= saa7231_i2c_xfer,
	.functionality	= saa7231_i2c_func,
};

static const char *i2c_rate_desc[] = {
	"Unknown",
	"400kHz",
	"100kHz"
};

int saa7231_i2c_init(struct saa7231_dev *saa7231)
{
	struct pci_dev *pdev		= saa7231->pdev;
	struct saa7231_i2c *i2c		= NULL;
	struct i2c_adapter *adapter	= NULL;

	int i, err = 0;

	mutex_lock(&saa7231->dev_lock);
	i2c = kzalloc((sizeof (struct saa7231_i2c) * SAA7231_I2C_ADAPTERS), GFP_KERNEL);
	if (i2c == NULL) {
		dprintk(SAA7231_ERROR, 1, "ERROR: Could not allocate I2C adapters");
		mutex_unlock(&saa7231->dev_lock);
		return -ENOMEM;
	}
	saa7231->i2c = i2c;

	for (i = 0; i < SAA7231_I2C_ADAPTERS; i++) {

		mutex_init(&i2c->i2c_lock);
		i2c->i2c_dev	= i;
		i2c->i2c_rate	= saa7231->config->i2c_rate;
		adapter		= &i2c->i2c_adapter;

		if (adapter != NULL) {

			i2c_set_adapdata(adapter, i2c);
			strcpy(adapter->name, SAA7231_I2C_ADAPTER_NAME(i));

			adapter->owner		= THIS_MODULE;
			adapter->algo		= &saa7231_algo;
			adapter->algo_data 	= NULL;
			adapter->timeout	= 500;
			adapter->retries	= 3;
			adapter->dev.parent	= &pdev->dev;

			dprintk(SAA7231_DEBUG, 1, "Initializing Adapter:%d (0x%02x) %s @ %s",
				i,
				SAA7231_I2C_ADAP(i),
				adapter->name,
				i2c_rate_desc[i2c->i2c_rate]);

			err = i2c_add_adapter(adapter);
			if (err < 0) {
				dprintk(SAA7231_ERROR, 1, "Adapter (%d) %s init failed", i, adapter->name);
				goto exit;
			}

			i2c->saa7231 = saa7231;
			saa7231_i2c_hwinit(i2c, SAA7231_I2C_ADAP(i));
		}
		i2c++;
	}

	dprintk(SAA7231_DEBUG, 1, "SAA%02x I2C Core succesfully initialized", saa7231->pdev->device);
	mutex_unlock(&saa7231->dev_lock);
	return 0;
exit:
	mutex_unlock(&saa7231->dev_lock);
	return err;
}
EXPORT_SYMBOL_GPL(saa7231_i2c_init);

int saa7231_i2c_exit(struct saa7231_dev *saa7231)
{
	struct saa7231_i2c *i2c		= saa7231->i2c;
	struct i2c_adapter *adapter	= NULL;
	int i;

	dprintk(SAA7231_DEBUG, 1, "Removing SAA%02x I2C Core", saa7231->pdev->device);
	mutex_lock(&saa7231->dev_lock);
	for (i = 0; i < SAA7231_I2C_ADAPTERS; i++) {

		adapter = &i2c->i2c_adapter;
		if (adapter) {
			dprintk(SAA7231_DEBUG, 1, "Removing adapter (%d) %s", i, adapter->name);
			i2c_del_adapter(adapter);
		}
		i2c++;
	}
	dprintk(SAA7231_DEBUG, 1, "SAA%02x I2C Core succesfully removed", saa7231->pdev->device);
	i2c = saa7231->i2c;
	kfree(i2c);
	mutex_unlock(&saa7231->dev_lock);
	return 0;
}
EXPORT_SYMBOL_GPL(saa7231_i2c_exit);
