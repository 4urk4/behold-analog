/*
 *	SAA7231xx PCI/PCI Express bridge driver
 *
 *	Analog video capture (V4L2) for the AVIS video decoder and the
 *	VS2D_AVIS DMA engine.  Register programming follows the vendor
 *	saa7231.sys driver; see logs/analog_init.md in the project.
 *
 *	This program is free software; you can redistribute it and/or modify
 *	it under the terms of the GNU General Public License as published by
 *	the Free Software Foundation; either version 2 of the License, or
 *	(at your option) any later version.
 */

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/kthread.h>
#include <linux/delay.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/pci.h>

#include <media/v4l2-device.h>
#include <media/v4l2-ioctl.h>
#include <media/v4l2-ctrls.h>
#include <media/videobuf2-v4l2.h>
#include <media/videobuf2-vmalloc.h>

#include "saa7231_mod.h"
#include "saa7231_priv.h"
#include "saa7231_cgu.h"
#include "saa7231_dmabuf.h"
#include "saa7231_dtl.h"
#include "saa7231_stream.h"
#include "saa7231_xs2dtl.h"
#include "saa7231_vfl.h"
#include "saa7231_audio.h"

#define VFL_WIDTH	720
#define VFL_HEIGHT	576
#define VFL_BPL		(VFL_WIDTH * 2)
#define VFL_SIZE	(VFL_BPL * VFL_HEIGHT)
#define VFL_BUFFERS	4

/*
 * Programming the decoder touches registers the vendor driver only writes
 * after a full filter graph is built, so keep it opt-in until the sequence
 * has been verified on this board.
 */
static unsigned int dec_init;
module_param(dec_init, int, 0644);
MODULE_PARM_DESC(dec_init, "Program the AVIS analog decoder on stream start (default 0)");

/* FUN_00023078 start path writes 0x16 to DCSC (BAR0 + 0x2ff000) */
static unsigned int dcsc_power;
module_param(dcsc_power, int, 0644);
MODULE_PARM_DESC(dcsc_power, "Write DCSC=0x16 on stream start (default 0)");

/* FUN_00023ff4: 0x2288 = (flags << 3) | (format << 4).  For the YUY2 media
 * subtype (2) the vendor value is 0x00; 0x10 is UYVY.  With the old 0x10 the
 * AVIS emitted 8-bit luma and the S2D padded U/V with 0x80 (gray). */
static unsigned int avis_fmt;
module_param(avis_fmt, uint, 0644);
MODULE_PARM_DESC(avis_fmt, "AVIS 0x2288 digital output format (default 0 = YUY2)");

/* 0x22c0 = 0x70 for subtype >= 10, 0x72 for subtype 0 (FUN_00023ff4) */
static unsigned int avis_c0 = 0x70;
module_param(avis_c0, uint, 0644);
MODULE_PARM_DESC(avis_c0, "AVIS 0x22c0 value (default 0x70)");

/* FUN_00023078/FUN_00022894 start: AUDIO block PLL registers (0x801xx) */
static unsigned int audio_pll;
module_param(audio_pll, uint, 0644);
MODULE_PARM_DESC(audio_pll, "Program AUDIO 0x1e8/0x1d4/0x1d0 on stream start (default 0)");

/* FUN_0001f2c0: AVIS ADC clock select in CGU 0xd24 (we never wrote it) */
static unsigned int adc_clk;
module_param(adc_clk, uint, 0644);
MODULE_PARM_DESC(adc_clk, "Program CGU 0xd24 ADC clock select like FUN_0001e3a8 (default 0)");

/* FUN_000248e4(1): clocks on, 0x2398=0xa0, 0x239c=1.  The vendor SD path
 * calls it with 0; allow the enabled state for testing. */
static unsigned int stream_on;
module_param(stream_on, uint, 0644);
MODULE_PARM_DESC(stream_on, "Use the FUN_000248e4(1) enabled state (default 0)");

/* FUN_0002476c has two register sets, chosen by 0x239c bit 0; we normally
 * program the status[1]==0 one.  Allow the other one for testing. */
static unsigned int digout_alt;
module_param(digout_alt, uint, 0644);
MODULE_PARM_DESC(digout_alt, "Use the FUN_0002476c status[1]!=0 DIGOUT values (default 0)");

/* Windows reference dump (logs/win_avis_run.txt) shows extra ADC routing
 * bits in AVIS 0x14/0x20 and two registers (0x24/0x28) we never write.
 * They are not produced by FUN_0001e3a8 for type 3, so take them verbatim. */
static unsigned int avis_adc_ref;
module_param(avis_adc_ref, int, 0644);
MODULE_PARM_DESC(avis_adc_ref, "Apply the Windows-reference ADC routing 0x14/0x20/0x24/0x28 (default 0)");

/* debug: fill the DMA ring with 0xaa before start to see what S2D writes */
static unsigned int fill_aa;
module_param(fill_aa, uint, 0644);
MODULE_PARM_DESC(fill_aa, "Fill DMA buffers with 0xaa before streaming (debug, default 0)");

/* override AVIS 0x48 (peak/macrovision/noise-reduction bits) for tests */
static int avis_48 = -1;
module_param(avis_48, int, 0644);
MODULE_PARM_DESC(avis_48, "Override AVIS 0x48 (default -1 = vendor defaults)");

/* FUN_00027a10/FUN_00026cd4/FUN_000272d0/FUN_000273b0: vendor analog
 * ADC start sequence.  We never programmed the 0x280000 block, so the
 * ADC control/gain registers stayed at reset defaults.  Composite type 3
 * maps to ADC control 0xc0120 | 0x200 (input powered) and gain 3/0x50000. */
static unsigned int adc_start;
module_param(adc_start, uint, 0644);
MODULE_PARM_DESC(adc_start, "Program vendor ADC start sequence (default 0)");

/* debug: copy the DMA lines verbatim instead of weaving fields */
static unsigned int raw_dump;
module_param(raw_dump, uint, 0644);
MODULE_PARM_DESC(raw_dump, "Copy raw S2D lines into frames (debug, default 0)");

/*
 * The vendor S2D setup for YUY2 delivers 1440-byte packed YUY2 lines.
 * packed_src=1 copies them verbatim; packed_src=0 keeps the old 8-bit
 * luma expansion path (720 used bytes per line, neutral chroma).
 */
static unsigned int packed_src = 1;
module_param(packed_src, uint, 0644);
MODULE_PARM_DESC(packed_src, "DMA lines are packed YUY2 (default 1); 0 = legacy 8-bit luma");

struct saa7231_vfl;

struct vfl_input {
	const char	*name;
	u32		type;
};

static const struct vfl_input vfl_inputs[] = {
	{ "Composite", 3 },
	{ "S-Video", 9 },
	{ "YPbPr", 10 },
	{ "RGB", 12 },
};

struct saa7231_vfl {
	struct saa7231_dev	*saa7231;

	struct v4l2_device	v4l2_dev;
	struct video_device	*vdev;
	struct vb2_queue	queue;
	struct mutex		lock;

	struct v4l2_ctrl_handler ctrl_handler;
	struct v4l2_ctrl	*brightness;
	struct v4l2_ctrl	*contrast;
	struct v4l2_ctrl	*saturation;
	struct v4l2_ctrl	*hue;
	struct v4l2_ctrl	*sharpness;

	struct saa7231_stream	*stream;
	struct task_struct	*thread;

	spinlock_t		qlock;
	u32			queued[VB2_MAX_FRAME];
	u32			qhead;
	u32			qcount;

	u32			last_index;
	u32			input;
	u32			frames;
	u32			field;
	struct vb2_buffer	*cur;
};

static void avis_wr(struct saa7231_dev *saa7231, u32 off, u32 val)
{
	SAA7231_WR(val, SAA7231_BAR0, AVIS, off);
}

static void avis_rmw(struct saa7231_dev *saa7231, u32 off, u32 val, u32 mask)
{
	u32 tmp = SAA7231_RD(SAA7231_BAR0, AVIS, off);

	SAA7231_WR((tmp & ~mask) | (val & mask), SAA7231_BAR0, AVIS, off);
}

/* FUN_00024af4: per-input AVIS window (registers 0x00..0x60) */
static void saa7231_avis_input(struct saa7231_dev *saa7231, u32 type)
{
	u32 r04 = 0x4107050, r08 = 0x410c050, r0c = 0x410e050, r10 = 0x410f050;
	u32 r40 = 0, r44 = 0, r48, r4c = 0x15e015e, r50 = 0x15e015e;
	u32 r54 = 0xf00200, r58 = 0x2000200, r5c = 0x3333;
	u32 gain = 0x40;

	switch (type) {
	case 3:		/* composite */
		r04 = 0x4305252;
		r48 = 0xb71070;
		break;
	case 9:		/* S-Video */
		r04 = 0x4303454;
		r0c = 0x430a454;
		r40 = 3;
		r44 = 1;
		r48 = 0xb710d0;
		r4c = 0x200015e;
		break;
	case 10:	/* YPbPr */
		r04 = 0x4306151;
		r08 = 0x4304858;
		r10 = 0x4307858;
		r40 = 0x254;
		r48 = 0xb710f0;
		r4c = 0x2000200;
		r50 = 0x15e0118;
		r54 = 0xf00040;
		gain = 0x6d;
		break;
	default:	/* 12: RGB */
		r04 = 0x4306151;
		r08 = 0x4304858;
		r0c = 0x430e151;
		r10 = 0x4307858;
		r40 = 0x253;
		r48 = 0xb710f0;
		r4c = 0x400040;
		r50 = 0x15e0040;
		r54 = 0xf00040;
		r58 = 0x400040;
		r5c = 0x4434;
		gain = 0x63;
		break;
	}
	/*
	 * FUN_00024af4 + constructor defaults (FUN_00024f78):
	 * White Peak Control=1, Color Peak Control=1, MacroVision=1,
	 * Noise Reduction=0.  The vendor clears 0x100/0x200/0x800 and sets
	 * 0x8 for these defaults.  Bit 0x8 was cleared by our old code and
	 * 0x800 was wrongly set; fix both.
	 */
	r48 &= ~(0x100 | 0x200 | 0x800);
	r48 |= 0x8;
	if (avis_48 >= 0)
		r48 = avis_48;

	avis_wr(saa7231, 0x00, 0);
	avis_wr(saa7231, 0x04, r04);
	avis_wr(saa7231, 0x08, r08);
	avis_wr(saa7231, 0x0c, r0c);
	avis_wr(saa7231, 0x10, r10);
	avis_wr(saa7231, 0x40, r40);
	avis_wr(saa7231, 0x44, r44);
	avis_wr(saa7231, 0x48, r48);
	avis_wr(saa7231, 0x4c, r4c);
	avis_wr(saa7231, 0x50, r50);
	avis_wr(saa7231, 0x54, r54);
	avis_wr(saa7231, 0x58, r58);
	avis_wr(saa7231, 0x5c, r5c);
	avis_wr(saa7231, 0x60, (gain << 24) | (gain << 16) | (gain << 8) | gain);
	avis_wr(saa7231, 0x00, 2);
	avis_wr(saa7231, 0x00, 1);
}

/* FUN_000252c0 + FUN_000236c8 + PAL timing for the given crossbar type */
static void saa7231_avis_program(struct saa7231_dev *saa7231, u32 type)
{
	u32 off;

	/* FUN_00023078, mode 1 */
	if (dcsc_power)
		SAA7231_WR(0x16, SAA7231_BAR0, DCSC, 0);
	if (audio_pll) {
		SAA7231_WR(1, SAA7231_BAR0, AUDIO, 0x1e8);
		SAA7231_WR(0x324bca, SAA7231_BAR0, AUDIO, 0x1d4);
	}
	avis_wr(saa7231, 0x3660, 4);
	if (audio_pll)
		SAA7231_WR(0x1801090, SAA7231_BAR0, AUDIO, 0x1d0);

	avis_wr(saa7231, 0x2240, 0x88);
	avis_wr(saa7231, 0x2268, 0x40);
	for (off = 0x30d4; off < 0x3118; off += 4)
		avis_wr(saa7231, off, 0xcc);
	avis_wr(saa7231, 0x3118, 0xcf);
	avis_wr(saa7231, 0x3128, 0x51);
	avis_wr(saa7231, 0x312c, 3);
	avis_wr(saa7231, 0x3140, 3);
	avis_wr(saa7231, 0x3144, 0);

	/* FUN_000249f0(0x397, 0x27) */
	avis_wr(saa7231, 0x2380, 3);
	avis_wr(saa7231, 0x2384, 0x27);
	avis_wr(saa7231, 0x2388, 0x97);

	/* FUN_00025474 */
	avis_wr(saa7231, 0x2670, 1);
	avis_wr(saa7231, 0x2680, 0x2f);
	avis_wr(saa7231, 0x2684, 0x8b);
	avis_wr(saa7231, 0x2688, 1);
	avis_wr(saa7231, 0x268c, 0);
	avis_wr(saa7231, 0x2690, 0);
	avis_wr(saa7231, 0x2694, 0);
	avis_wr(saa7231, 0x2698, 1);
	avis_wr(saa7231, 0x2600, 0x44);
	avis_wr(saa7231, 0x2604, 0x11);
	avis_wr(saa7231, 0x2608, 0);
	avis_wr(saa7231, 0x260c, 0x10);
	avis_wr(saa7231, 0x2610, 4);
	avis_wr(saa7231, 0x2614, 0x22);
	avis_wr(saa7231, 0x2618, 0x10);
	avis_wr(saa7231, 0x261c, 0x14);
	avis_wr(saa7231, 0x2620, 1);
	avis_wr(saa7231, 0x2624, 0x10);
	avis_wr(saa7231, 0x2628, 9);
	avis_wr(saa7231, 0x262c, 0xf0);
	avis_wr(saa7231, 0x2630, 5);
	avis_wr(saa7231, 0x2634, 0x40);
	avis_wr(saa7231, 0x269c, 0);
	avis_wr(saa7231, 0x26a0, 0);
	avis_wr(saa7231, 0x26a4, 0x80);

	avis_wr(saa7231, 0x1004, 0x28000104);
	avis_wr(saa7231, 0x104c, 0x8e4ef08);
	avis_wr(saa7231, 0x105c, 0x36191);
	pr_info("saa7231 avis: base init done\n");

	/* FUN_00023838: brightness, contrast, saturation, hue, sharpness */
	avis_wr(saa7231, 0x2270, 0x80);
	avis_wr(saa7231, 0x2424, 0x80);
	avis_wr(saa7231, 0x2274, 0x44);
	avis_wr(saa7231, 0x2428, 0x40);
	avis_wr(saa7231, 0x2280, 0x40);
	avis_wr(saa7231, 0x242c, 0x40);
	avis_wr(saa7231, 0x2284, 0);
	avis_rmw(saa7231, 0x2260, 0, 0xf00);
	avis_rmw(saa7231, 0x2414, 0, 0x8);

	/* FUN_0001e3a8: analog input routing (AVIS 0x14/0x20/0x24) */
	switch (type) {
	case 3:
		avis_rmw(saa7231, 0x14, 0x10300000, 0x1ff00000);
		avis_rmw(saa7231, 0x20, 0x01340000, 0xffff0000);
		break;
	case 9:
		avis_rmw(saa7231, 0x14, 0x10303000, 0x1ffff000);
		avis_rmw(saa7231, 0x20, 0x3340234, 0xffffffff);
		break;
	case 10:
		avis_rmw(saa7231, 0x14, 0x10303000, 0x1ffff000);
		avis_rmw(saa7231, 0x20, 0x3340334, 0xffffffff);
		break;
	default:	/* 12: RGB */
		avis_rmw(saa7231, 0x14, 0x10023130, 0xf00ffff0);
		avis_rmw(saa7231, 0x20, 0x434, 0xffff);
		avis_rmw(saa7231, 0x24, 0x4340000, 0xffffffff);
		break;
	}

	if (avis_adc_ref) {
		avis_wr(saa7231, 0x14, 0x10303030);
		avis_wr(saa7231, 0x20, 0x01340031);
		avis_wr(saa7231, 0x24, 0x00310000);
		avis_wr(saa7231, 0x28, 0x00111111);
	}
	if (avis_adc_ref > 1) {
		avis_wr(saa7231, 0x64, 0x00800080);
		avis_wr(saa7231, 0x68, 0x168);
		avis_wr(saa7231, 0x70, 0x8f1010);
		avis_wr(saa7231, 0x74, 0x1610372c);
		avis_wr(saa7231, 0xb0, 0x60);
	}

	/* FUN_0001f2c0: ADC clock select, mask/value depend on the input */
	if (adc_clk) {
		u32 mask = type < 8 ? 0x3 : (type < 11 ? 0xf : 0x30);
		u32 val = type < 8 ? 0x2 : (type < 11 ? 0xa : 0);
		u32 reg = SAA7231_RD(SAA7231_BAR0, CGU, 0xd24);

		SAA7231_WR((reg & ~mask) | val, SAA7231_BAR0, CGU, 0xd24);
	}

	/* FUN_00026f38(1): power the external analog input (AUDIO+0x5c bit 9) */
	if (!(SAA7231_RD(SAA7231_BAR0, AUDIO, 0x5c) & 0x200)) {
		u32 v = SAA7231_RD(SAA7231_BAR0, AUDIO, 0x5c);

		SAA7231_WR(v | 0x200, SAA7231_BAR0, AUDIO, 0x5c);
		msleep(15);
	}

	saa7231_avis_input(saa7231, type);
	pr_info("saa7231 avis: input table done\n");

	/* FUN_000236c8 tail */
	avis_wr(saa7231, 0x2410, type >= 10 ? 1 : 0);
	avis_rmw(saa7231, 0x2414, type < 12 ? 0x10 : 0, 0x10);

	/* FUN_000248e4(stream_on): SD path uses x=0 (vendor FUN_000236c8) */
	if (stream_on) {
		avis_rmw(saa7231, 0x44, 0xff000, 0xff000);
		avis_wr(saa7231, 0x2398, 0xa0);
		avis_wr(saa7231, 0x239c, 1);
	} else {
		avis_rmw(saa7231, 0x44, 0, 0xff000);
		avis_wr(saa7231, 0x2398, 0xa4);
		avis_wr(saa7231, 0x239c, 0);
	}
	avis_wr(saa7231, 0x33f4, 0);

	if (type < 10) {
		avis_wr(saa7231, 0x2250, 0x24);
		avis_wr(saa7231, 0x2294, 1);
		avis_wr(saa7231, 0x22c4, 0x87);
		avis_wr(saa7231, 0x22a0, 0xa9);
	}

	/* FUN_00023ff4 for the YUY2 media subtype; 0x80 is written first */
	avis_wr(saa7231, 0x2288, avis_fmt | 0x80);
	avis_wr(saa7231, 0x2288, avis_fmt);
	avis_wr(saa7231, 0x2290, type == 9 ? 0xe : 6);
	avis_rmw(saa7231, 0x2260, (type == 9 ? 0xc : 4) << 4, 0xf0);
	avis_wr(saa7231, 0x22c0, avis_c0);
	avis_wr(saa7231, 0x22a4, type == 9 ? 1 : 0xc1);

	if (type < 10)
		avis_wr(saa7231, 0x2250, 0x24);

	avis_wr(saa7231, 0x2244, 0x8d);	/* V-Sync recovery, mode 0 */
	avis_wr(saa7231, 0x2264, 0);	/* Luma shift */
	pr_info("saa7231 avis: input setup done\n");

	/* PAL, status[1] = 1 */
	avis_wr(saa7231, 0x334c, 1);
	avis_wr(saa7231, 0x33b0, 0);
	avis_wr(saa7231, 0x33b4, 0);
	avis_wr(saa7231, 0x33b8, 0);
	avis_wr(saa7231, 0x33bc, 0);
	avis_wr(saa7231, 0x33f0, 3);
	avis_wr(saa7231, 0x3128, 0x51);
	avis_wr(saa7231, 0x3140, 3);
	avis_wr(saa7231, 0x3114, 0xcc);
	avis_wr(saa7231, 0x3118, 0xcf);
	avis_wr(saa7231, 0x104c, 0x8e4ef08);
	avis_wr(saa7231, 0x105c, 0x36191);
	avis_wr(saa7231, 0x2380, 3);
	avis_wr(saa7231, 0x2384, 0x27);
	avis_wr(saa7231, 0x2388, 0x97);

	/* FUN_0002476c; status[1] = 0x239c & 1, branch selectable for testing */
	avis_wr(saa7231, 0x33c0, digout_alt ? 0x58 : 0x2f);
	avis_wr(saa7231, 0x33c4, 0);
	avis_wr(saa7231, 0x33c8, digout_alt ? 0xd6 : 1);
	avis_wr(saa7231, 0x33cc, digout_alt ? 4 : 0);
	avis_wr(saa7231, 0x33f4, stream_on ? 0 : 1);

	/* FUN_0002483c */
	avis_wr(saa7231, 0x3390, 0xa4);
	avis_wr(saa7231, 0x3394, 0xf);
	avis_wr(saa7231, 0x3398, 0x34);
	avis_wr(saa7231, 0x339c, 0);
	avis_wr(saa7231, 0x33a0, 0xb);
	avis_wr(saa7231, 0x33a4, 0);
	avis_wr(saa7231, 0x33a8, 1);
	avis_wr(saa7231, 0x33ac, 0);
	pr_info("saa7231 avis: timing done\n");

	/*
	 * FUN_00027a10: vendor start sequence for the 0x280000 analog
	 * block.  FUN_00026f38(1) has already set bit 9 (input powered);
	 * FUN_00026cd4 then writes the type-specific ADC control value.
	 * FUN_000272d0 selects the ADC clock/bias for the composite input,
	 * FUN_000273b0 sets the per-input ADC gain/offset.
	 */
	if (adc_start) {
		u32 v;

		if (type == 3) {
			v = SAA7231_RD(SAA7231_BAR0, AUDIO, 0x18c);
			SAA7231_WR((v & ~0x3000) | 0x2000, SAA7231_BAR0,
				   AUDIO, 0x18c);
			SAA7231_WR(0xc0120 | 0x200, SAA7231_BAR0, AUDIO, 0x5c);
			SAA7231_WR(3, SAA7231_BAR0, AUDIO, 0x80);
			SAA7231_WR(0x50000, SAA7231_BAR0, AUDIO, 0x90);
		}
		pr_info("saa7231 avis: adc start done (type %u)\n", type);
	}
}

/*
 * FUN_00023838: the five IAMVideoProcAmp controls.  The vendor writes the
 * 0x2424/0x2428/0x242c twins too; they keep their defaults here.
 */
static void vfl_apply_ctrls(struct saa7231_vfl *v)
{
	avis_wr(v->saa7231, 0x2270, v->brightness->val);
	avis_wr(v->saa7231, 0x2274, v->contrast->val);
	avis_wr(v->saa7231, 0x2280, v->saturation->val);
	avis_wr(v->saa7231, 0x2284, (u32)v->hue->val);
	avis_rmw(v->saa7231, 0x2260, v->sharpness->val << 8, 0xf00);
}

static int vfl_s_ctrl(struct v4l2_ctrl *ctrl)
{
	struct saa7231_vfl *v =
		container_of(ctrl->handler, struct saa7231_vfl, ctrl_handler);

	/* AVIS registers only mean anything while the decoder is running */
	if (v->stream)
		vfl_apply_ctrls(v);
	return 0;
}

static const struct v4l2_ctrl_ops vfl_ctrl_ops = {
	.s_ctrl = vfl_s_ctrl,
};

/*
 * The decoder delivers one field per S2D buffer: 720 YUY2 pixels per
 * 1440-byte line, 288 lines.  Two fields are weaved into one 720x576
 * YUY2 frame.
 */
static void vfl_complete(struct saa7231_vfl *v, u32 dma_index)
{
	struct vb2_buffer *vb = v->cur;
	unsigned long flags;
	u8 *src, *dst;
	u32 index;
	int r, x;

	if (dma_index >= XS2D_BUFFERS || !v->stream)
		return;

	if (!vb) {
		if (!v->qcount)
			return;
		spin_lock_irqsave(&v->qlock, flags);
		index = v->queued[v->qhead];
		v->qhead = (v->qhead + 1) % VB2_MAX_FRAME;
		v->qcount--;
		spin_unlock_irqrestore(&v->qlock, flags);

		vb = vb2_get_buffer(&v->queue, index);
		if (!vb)
			return;
		v->cur = vb;
	}

	src = v->stream->ring->dmabuf[dma_index].virt;
	dst = vb2_plane_vaddr(vb, 0);
	if (!dst)
		return;

	if (raw_dump) {
		/* debug: hand the whole DMA buffer to the user untouched */
		memcpy(dst, src, VFL_SIZE);
		goto done;
	}

	for (r = 0; r < VFL_HEIGHT / 2; r++) {
		const u8 *s = src + r * VFL_BPL;
		u8 *d = dst + (2 * r + v->field) * VFL_BPL;

		if (packed_src) {
			memcpy(d, s, VFL_BPL);
			continue;
		}
		for (x = 0; x < VFL_WIDTH / 2; x++) {
			d[4 * x + 0] = s[2 * x + 0];
			d[4 * x + 1] = 128;
			d[4 * x + 2] = s[2 * x + 1];
			d[4 * x + 3] = 128;
		}
	}

done:
	if (v->field) {
		vb2_set_plane_payload(vb, 0, VFL_SIZE);
		vb2_buffer_done(vb, VB2_BUF_STATE_DONE);
		v->cur = NULL;
		if (!v->frames++)
			pr_info("saa7231 vfl: first frame (dma %u)\n", dma_index);
	}
	v->field ^= 1;
}

static int vfl_thread(void *data)
{
	struct saa7231_vfl *v = data;
	u32 index, fid;

	while (!kthread_should_stop()) {
		if (v->stream && !v->stream->ops.get_buffer(v->stream, &index, &fid)) {
			if (index != v->last_index) {
				vfl_complete(v, v->last_index);
				v->last_index = index;
			}
		}
		msleep(10);
	}
	return 0;
}

static int vfl_queue_setup(struct vb2_queue *q, unsigned int *nbuffers,
			   unsigned int *nplanes, unsigned int sizes[],
			   struct device *alloc_devs[])
{
	if (*nplanes) {
		if (sizes[0] < VFL_SIZE)
			return -EINVAL;
		return 0;
	}
	if (*nbuffers < VFL_BUFFERS)
		*nbuffers = VFL_BUFFERS;
	*nplanes = 1;
	sizes[0] = VFL_SIZE;
	return 0;
}

static int vfl_buf_prepare(struct vb2_buffer *vb)
{
	struct vb2_v4l2_buffer *vbuf = to_vb2_v4l2_buffer(vb);

	vbuf->field = V4L2_FIELD_INTERLACED;
	return 0;
}

static int vfl_start_streaming(struct vb2_queue *q, unsigned int count)
{
	struct saa7231_vfl *v = q->drv_priv;
	struct saa7231_stream *stream;
	int ret;

	pr_info("saa7231 vfl: start, allocating stream\n");
	stream = saa7231_stream_init(v->saa7231, VIDEO_CAPTURE, ADAPTER_INT, 0,
				     CALC_PAGES(VFL_BPL, VFL_HEIGHT));
	if (!stream)
		return -ENOMEM;
	pr_info("saa7231 vfl: stream allocated\n");

	stream->params.bps	= 16;
	stream->params.spl	= 2;
	stream->params.pitch	= VFL_BPL;
	stream->params.lines	= VFL_HEIGHT;
	stream->params.flags	= 0;
	stream->params.type	= STREAM_VIDEO;
	stream->params.size	= VFL_SIZE;

	pr_info("saa7231 vfl: acquire\n");
	ret = stream->ops.acquire(stream);
	if (ret)
		goto err;

	if (fill_aa) {
		int i;

		for (i = 0; i < XS2D_BUFFERS; i++)
			memset(stream->ring->dmabuf[i].virt, 0xaa, VFL_SIZE);
	}

	if (dec_init) {
		pr_info("saa7231 vfl: avis program, input type %u\n",
			vfl_inputs[v->input].type);
		saa7231_avis_program(v->saa7231, vfl_inputs[v->input].type);
		vfl_apply_ctrls(v);
		pr_info("saa7231 vfl: avis program done\n");
	}

	pr_info("saa7231 vfl: run\n");
	ret = stream->ops.run(stream);
	if (ret)
		goto err;

	ret = saa7231_audio_start(v->saa7231);
	if (ret && ret != -EBUSY)
		pr_warn("saa7231 vfl: audio start failed: %d\n", ret);
	pr_info("saa7231 vfl: streaming\n");

	/* buffers queued before STREAMON are already in v->queued[] */
	v->stream = stream;
	v->last_index = ~0;
	v->frames = 0;
	v->field = 0;
	v->cur = NULL;
	v->thread = kthread_run(vfl_thread, v, "saa7231-vfl");
	if (IS_ERR(v->thread)) {
		v->thread = NULL;
		stream->ops.pause(stream);
		ret = -ENOMEM;
		goto err;
	}
	return 0;
err:
	saa7231_stream_exit(stream);
	return ret;
}

static void vfl_stop_streaming(struct vb2_queue *q)
{
	struct saa7231_vfl *v = q->drv_priv;

	saa7231_audio_stop(v->saa7231);
	if (v->thread) {
		kthread_stop(v->thread);
		v->thread = NULL;
	}
	if (v->stream) {
		v->stream->ops.pause(v->stream);
		v->stream->ops.stop(v->stream);
		saa7231_stream_exit(v->stream);
		v->stream = NULL;
	}
	if (v->cur) {
		vb2_buffer_done(v->cur, VB2_BUF_STATE_ERROR);
		v->cur = NULL;
	}
	pr_info("saa7231 vfl: stop, frames=%u\n", v->frames);

	while (v->qcount) {
		struct vb2_buffer *vb;
		u32 index = v->queued[v->qhead];

		v->qhead = (v->qhead + 1) % VB2_MAX_FRAME;
		v->qcount--;
		vb = vb2_get_buffer(q, index);
		if (vb)
			vb2_buffer_done(vb, VB2_BUF_STATE_ERROR);
	}
}

static void vfl_buf_queue(struct vb2_buffer *vb)
{
	struct saa7231_vfl *v = vb->vb2_queue->drv_priv;
	unsigned long flags;

	spin_lock_irqsave(&v->qlock, flags);
	v->queued[(v->qhead + v->qcount) % VB2_MAX_FRAME] = vb->index;
	v->qcount++;
	spin_unlock_irqrestore(&v->qlock, flags);
}

static const struct vb2_ops vfl_vb2_ops = {
	.queue_setup		= vfl_queue_setup,
	.buf_prepare		= vfl_buf_prepare,
	.start_streaming	= vfl_start_streaming,
	.stop_streaming		= vfl_stop_streaming,
	.buf_queue		= vfl_buf_queue,
};

static int vfl_querycap(struct file *file, void *priv,
			struct v4l2_capability *cap)
{
	struct saa7231_vfl *v = video_drvdata(file);

	strscpy(cap->driver, "saa7231", sizeof(cap->driver));
	strscpy(cap->card, "Behold TV H8", sizeof(cap->card));
	snprintf(cap->bus_info, sizeof(cap->bus_info), "PCI:%s",
		 pci_name(v->saa7231->pdev));
	cap->device_caps = V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_STREAMING;
	cap->capabilities = cap->device_caps | V4L2_CAP_DEVICE_CAPS;
	return 0;
}

static int vfl_enum_input(struct file *file, void *priv, struct v4l2_input *inp)
{
	if (inp->index >= ARRAY_SIZE(vfl_inputs))
		return -EINVAL;
	strscpy(inp->name, vfl_inputs[inp->index].name, sizeof(inp->name));
	inp->type = V4L2_INPUT_TYPE_CAMERA;
	inp->std = V4L2_STD_PAL;	/* NTSC needs 240-line fields, not done */
	return 0;
}

static int vfl_g_input(struct file *file, void *priv, unsigned int *i)
{
	struct saa7231_vfl *v = video_drvdata(file);

	*i = v->input;
	return 0;
}

static int vfl_s_input(struct file *file, void *priv, unsigned int i)
{
	struct saa7231_vfl *v = video_drvdata(file);

	if (i >= ARRAY_SIZE(vfl_inputs))
		return -EINVAL;
	if (vb2_is_busy(&v->queue))
		return -EBUSY;
	v->input = i;
	return 0;
}

static int vfl_enum_fmt(struct file *file, void *priv, struct v4l2_fmtdesc *f)
{
	if (f->index)
		return -EINVAL;
	f->pixelformat = V4L2_PIX_FMT_YUYV;
	strscpy(f->description, "YUYV 4:2:2", sizeof(f->description));
	return 0;
}

static void vfl_fill_fmt(struct v4l2_format *f)
{
	struct v4l2_pix_format *pix = &f->fmt.pix;

	pix->width		= VFL_WIDTH;
	pix->height		= VFL_HEIGHT;
	pix->pixelformat	= V4L2_PIX_FMT_YUYV;
	pix->field		= V4L2_FIELD_INTERLACED;
	pix->bytesperline	= VFL_BPL;
	pix->sizeimage		= VFL_SIZE;
	pix->colorspace		= V4L2_COLORSPACE_SRGB;
	pix->priv		= 0;
}

static int vfl_g_fmt(struct file *file, void *priv, struct v4l2_format *f)
{
	vfl_fill_fmt(f);
	return 0;
}

static int vfl_try_fmt(struct file *file, void *priv, struct v4l2_format *f)
{
	vfl_fill_fmt(f);
	return 0;
}

static int vfl_s_fmt(struct file *file, void *priv, struct v4l2_format *f)
{
	struct saa7231_vfl *v = video_drvdata(file);

	if (vb2_is_busy(&v->queue))
		return -EBUSY;
	vfl_fill_fmt(f);
	return 0;
}

static int vfl_g_parm(struct file *file, void *priv, struct v4l2_streamparm *p)
{
	if (p->type != V4L2_BUF_TYPE_VIDEO_CAPTURE)
		return -EINVAL;
	p->parm.capture.timeperframe.numerator = 1;
	p->parm.capture.timeperframe.denominator = 25;
	p->parm.capture.readbuffers = VFL_BUFFERS;
	return 0;
}

static int vfl_s_parm(struct file *file, void *priv, struct v4l2_streamparm *p)
{
	return vfl_g_parm(file, priv, p);
}

static const struct v4l2_ioctl_ops vfl_ioctl_ops = {
	.vidioc_querycap	= vfl_querycap,
	.vidioc_enum_input	= vfl_enum_input,
	.vidioc_g_input		= vfl_g_input,
	.vidioc_s_input		= vfl_s_input,
	.vidioc_enum_fmt_vid_cap = vfl_enum_fmt,
	.vidioc_g_fmt_vid_cap	= vfl_g_fmt,
	.vidioc_try_fmt_vid_cap	= vfl_try_fmt,
	.vidioc_s_fmt_vid_cap	= vfl_s_fmt,
	.vidioc_g_parm		= vfl_g_parm,
	.vidioc_s_parm		= vfl_s_parm,

	.vidioc_reqbufs		= vb2_ioctl_reqbufs,
	.vidioc_querybuf	= vb2_ioctl_querybuf,
	.vidioc_qbuf		= vb2_ioctl_qbuf,
	.vidioc_dqbuf		= vb2_ioctl_dqbuf,
	.vidioc_expbuf		= vb2_ioctl_expbuf,
	.vidioc_create_bufs	= vb2_ioctl_create_bufs,
	.vidioc_prepare_buf	= vb2_ioctl_prepare_buf,
	.vidioc_streamon	= vb2_ioctl_streamon,
	.vidioc_streamoff	= vb2_ioctl_streamoff,
};

static const struct v4l2_file_operations vfl_fops = {
	.owner		= THIS_MODULE,
	.open		= v4l2_fh_open,
	.release	= vb2_fop_release,
	.poll		= vb2_fop_poll,
	.unlocked_ioctl	= video_ioctl2,
	.mmap		= vb2_fop_mmap,
};

int saa7231_vfl_init(struct saa7231_dev *saa7231)
{
	struct saa7231_vfl *v;
	struct video_device *vdev;
	int ret;

	v = kzalloc(sizeof(*v), GFP_KERNEL);
	if (!v)
		return -ENOMEM;
	v->saa7231 = saa7231;
	mutex_init(&v->lock);
	spin_lock_init(&v->qlock);

	ret = v4l2_device_register(&saa7231->pdev->dev, &v->v4l2_dev);
	if (ret)
		goto err_free;

	/* defaults and ranges from FUN_00023838 / IAMVideoProcAmp */
	v4l2_ctrl_handler_init(&v->ctrl_handler, 5);
	v->brightness = v4l2_ctrl_new_std(&v->ctrl_handler, &vfl_ctrl_ops,
					  V4L2_CID_BRIGHTNESS,
					  0, 0xff, 1, 0x80);
	v->contrast = v4l2_ctrl_new_std(&v->ctrl_handler, &vfl_ctrl_ops,
					V4L2_CID_CONTRAST, 0, 0x7f, 1, 0x44);
	v->saturation = v4l2_ctrl_new_std(&v->ctrl_handler, &vfl_ctrl_ops,
					  V4L2_CID_SATURATION, 0, 0x7f, 1, 0x40);
	v->hue = v4l2_ctrl_new_std(&v->ctrl_handler, &vfl_ctrl_ops,
				   V4L2_CID_HUE, -0x7f, 0x7f, 1, 0);
	v->sharpness = v4l2_ctrl_new_std(&v->ctrl_handler, &vfl_ctrl_ops,
					 V4L2_CID_SHARPNESS, 0, 0xf, 1, 0);
	ret = v->ctrl_handler.error;
	if (ret)
		goto err_ctrl;

	v->queue.type		= V4L2_BUF_TYPE_VIDEO_CAPTURE;
	v->queue.io_modes	= VB2_MMAP;
	v->queue.drv_priv	= v;
	v->queue.buf_struct_size = sizeof(struct vb2_v4l2_buffer);
	v->queue.ops		= &vfl_vb2_ops;
	v->queue.mem_ops	= &vb2_vmalloc_memops;
	v->queue.timestamp_flags = V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC;
	v->queue.lock		= &v->lock;
	ret = vb2_queue_init(&v->queue);
	if (ret)
		goto err_v4l2;

	vdev = video_device_alloc();
	if (!vdev) {
		ret = -ENOMEM;
		goto err_v4l2;
	}
	vdev->v4l2_dev	= &v->v4l2_dev;
	vdev->ctrl_handler = &v->ctrl_handler;
	vdev->fops	= &vfl_fops;
	vdev->ioctl_ops	= &vfl_ioctl_ops;
	vdev->release	= video_device_release;
	vdev->lock	= &v->lock;
	vdev->queue	= &v->queue;
	vdev->vfl_dir	= VFL_DIR_RX;
	vdev->device_caps = V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_STREAMING;
	strscpy(vdev->name, "saa7231-vfl", sizeof(vdev->name));
	video_set_drvdata(vdev, v);

	ret = video_register_device(vdev, VFL_TYPE_VIDEO, -1);
	if (ret) {
		video_device_release(vdev);
		goto err_v4l2;
	}

	v->vdev = vdev;
	saa7231->vfl = v;
	dprintk(SAA7231_INFO, 1, "INFO: analog video device registered as %s",
		video_device_node_name(vdev));
	return 0;

err_v4l2:
	v4l2_ctrl_handler_free(&v->ctrl_handler);
err_ctrl:
	v4l2_device_unregister(&v->v4l2_dev);
err_free:
	kfree(v);
	return ret;
}
EXPORT_SYMBOL_GPL(saa7231_vfl_init);

void saa7231_vfl_exit(struct saa7231_dev *saa7231)
{
	struct saa7231_vfl *v = saa7231->vfl;

	if (!v)
		return;

	video_unregister_device(v->vdev);
	v4l2_ctrl_handler_free(&v->ctrl_handler);
	v4l2_device_unregister(&v->v4l2_dev);
	kfree(v);
	saa7231->vfl = NULL;
}
EXPORT_SYMBOL_GPL(saa7231_vfl_exit);
