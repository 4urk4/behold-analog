/*
 *	SAA7231xx PCI/PCI Express bridge driver
 *
 *	Analog audio capture: the audio ADC/DSP in the AUDIO block
 *	(BAR0 + 0x280000) feeding the AS2D_LOCAL DMA engine.  Register
 *	programming follows the vendor saa7231.sys driver (FUN_000260a0,
 *	FUN_00026cd4, FUN_000272d0, FUN_000273b0); see
 *	logs/analog_init.md in the project.
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
#include <linux/math.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/pci.h>

#include "saa7231_mod.h"
#include "saa7231_priv.h"
#include "saa7231_rgu_reg.h"
#include "saa7231_cgu.h"
#include "saa7231_dmabuf.h"
#include "saa7231_dtl.h"
#include "saa7231_stream.h"
#include "saa7231_xs2dtl.h"
#include "saa7231_audio.h"

#define AUD_BPS		16
#define AUD_CH		2
#define AUD_PITCH	(AUD_CH * AUD_BPS / 8)	/* 1 frame, bytes */
#define AUD_LINES	1024			/* 4096-byte buffer, as the vendor */
#define AUD_SIZE	(AUD_PITCH * AUD_LINES)

/* The vendor only writes the AUDIO block once the capture graph is built,
 * so keep it opt-in until the sequence has been verified on this board. */
static unsigned int audio_init;
module_param(audio_init, int, 0644);
MODULE_PARM_DESC(audio_init, "Program the analog audio decoder and start AS2D_LOCAL (default 0)");

/* Sample rate: 0 = 32000, 1 = 44100, 2 = 48000.  The vendor capture runs
 * at 48 kHz (0x8c=0x1801, 0x1a4 bit 0x1000 in the Windows reference). */
static unsigned int audio_rate = 2;
module_param(audio_rate, int, 0644);
MODULE_PARM_DESC(audio_rate, "Audio sample rate 0=32k 1=44.1k 2=48k (default 2)");

/* STREAM audio port: bit0 = Japan, bit1 = I2S mode, bit2 = SPDIF (1) or
 * I2S (0).  The AS2D sync is one block per 192 frames, i.e. the SPDIF
 * block length, so the SPDIF framing is a candidate. */
static unsigned int audio_config = 4;
module_param(audio_config, int, 0644);
MODULE_PARM_DESC(audio_config, "STREAM audio port config: bit2=1 SPDIF, 0=I2S (default 4)");

/* Audio crossbar index (FUN_000272d0); 0 and 1 are the only ones with a
 * known mapping (0x801c4 = 4 / 0). */
static unsigned int audio_input;
module_param(audio_input, int, 0644);
MODULE_PARM_DESC(audio_input, "Audio input index for the ADC select (default 0)");

/* "TV Audio Standard" property index -> AUDIO 0x5c code (FUN_00026d54).
 * The vendor default property value is 0, so 0xc010c is the default. */
static unsigned int audio_std;
module_param(audio_std, int, 0644);
MODULE_PARM_DESC(audio_std, "TV audio standard index 0..18 for AUDIO 0x5c (default 0 = 0xc010c)");

/* FUN_0001ff2c inside FUN_000260a0 pulses RGU_RESET_CTRL1 (0x10e104).
 * That register is known to hang this board with the vendor masks, so the
 * pulse stays off until we know it is needed. */
static unsigned int audio_rgu;
module_param(audio_rgu, int, 0644);
MODULE_PARM_DESC(audio_rgu, "Pulse RGU_RESET_CTRL1 during audio init (default 0, can hang)");

/* FUN_00026d54: audio standard index -> AUDIO 0x5c value */
static const u32 aud_std_code[] = {
	0xc010c, 0xc0108, 0xc0104, 0xc0120, 0xc0110, 0xc0140, 0xc0109,
	0xc0119, 0xc011d, 0xc0121, 0xc0125, 0xc0105, 0xc0111, 0xc0115,
	0xc012d, 0xc0129, 0xc0131, 0xc0135, 0xc0139,
};

struct saa7231_audio {
	struct saa7231_dev	*saa7231;
	struct saa7231_stream	*stream;
	struct task_struct	*thread;
	u32			buffers;
};

static struct saa7231_audio *audio_state;

static void aud_wr(struct saa7231_dev *saa7231, u32 off, u32 val)
{
	SAA7231_WR(val, SAA7231_BAR0, AUDIO, off);
}

/* FUN_00025644 writes through FUN_00023158, which routes offsets without
 * the 0x80000 tag into AVIS (0x200000), not into AUDIO. */
static void avis_wr(struct saa7231_dev *saa7231, u32 off, u32 val)
{
	SAA7231_WR(val, SAA7231_BAR0, AVIS, off);
}

static void aud_rmw(struct saa7231_dev *saa7231, u32 off, u32 val, u32 mask)
{
	u32 tmp = SAA7231_RD(SAA7231_BAR0, AUDIO, off);

	SAA7231_WR((tmp & ~mask) | (val & mask), SAA7231_BAR0, AUDIO, off);
}

/* FUN_000260a0 with neutral tone/balance and the vendor volume default */
static void saa7231_audio_program(struct saa7231_dev *saa7231)
{
	u32 clk = audio_rate == 1 ? 0x1401 : (audio_rate == 2 ? 0x1801 : 0x1001);
	u32 rate = audio_rate == 1 ? 0 : (audio_rate == 2 ? 0x1000 : 0x3000);

	/* FUN_00023078 start: audio PLL, written for every capture start */
	aud_wr(saa7231, 0x1e8, 1);
	aud_wr(saa7231, 0x1d4, 0x324bca);
	aud_wr(saa7231, 0x1d0, 0x1801090);

	aud_wr(saa7231, 0x198, 7);

	/* FUN_0001ff2c: reset pulse on the audio block */
	if (audio_rgu) {
		u32 act = SAA7231_RD(SAA7231_BAR0, RGU, RGU_RESET_ACTIVE1);

		SAA7231_WR(~act | 0xe0, SAA7231_BAR0, RGU, RGU_RESET_CTRL1);
		msleep(5);
		SAA7231_WR(~act & ~0xe0, SAA7231_BAR0, RGU, RGU_RESET_CTRL1);
		msleep(5);
	}

	aud_wr(saa7231, 0x1ec, 0);
	msleep(25);
	aud_wr(saa7231, 0x1f0, 3);
	aud_rmw(saa7231, 0x188, 0, 0x60000000);
	aud_rmw(saa7231, 0x1a4, rate, 0x3700);
	aud_rmw(saa7231, 0x18c, 2, 7);		/* stereo */
	aud_wr(saa7231, 0x8c, clk);

	/* FUN_00026cd4: audio standard code, bit 9 = input powered */
	aud_wr(saa7231, 0x5c, aud_std_code[audio_std % ARRAY_SIZE(aud_std_code)] | 0x200);

	/* values below copied from the Windows reference dump */
	aud_wr(saa7231, 0x54, 0xc8510);
	aud_wr(saa7231, 0x58, 0x14);
	aud_wr(saa7231, 0x64, 0x684bda);
	aud_wr(saa7231, 0x9c, 0x2cb2cb);
	aud_wr(saa7231, 0xa0, 0x40040);
	aud_wr(saa7231, 0xa4, 0x40040);
	aud_wr(saa7231, 0xa8, 0x78);

	/* FUN_00026be4/FUN_00026c90/FUN_00026c30 at neutral settings */
	aud_wr(saa7231, 0x84, 0);
	aud_wr(saa7231, 0x88, 0);
	aud_wr(saa7231, 0xb8, 0);
	aud_wr(saa7231, 0xc4, 0);
	aud_wr(saa7231, 0xd0, 0);
	aud_wr(saa7231, 0xd4, 0);
	aud_wr(saa7231, 0xac, 0x1c40);

	/* FUN_000272d0: ADC select for the audio crossbar index */
	aud_wr(saa7231, 0x1c4, audio_input == 1 ? 0 : 4);

	/* FUN_000273b0: ADC gain/offset as in the Windows reference */
	aud_wr(saa7231, 0x80, 3);
	aud_wr(saa7231, 0x90, 0x50000);

	aud_wr(saa7231, 0x80fe8, 0xffffffff);
	aud_wr(saa7231, 0x80fe4, 0x80000000);

	/* FUN_00025644: audio port, mode 0 — in the AVIS block.  0x1004 with
	 * bit 0x2000000 is the audio engine enable (0x28000104 = stop). */
	avis_wr(saa7231, 0x1008, 0x19028600);
	avis_wr(saa7231, 0x1018, 0x50800);
	avis_wr(saa7231, 0x1020, 0x1328);
	avis_wr(saa7231, 0x1038, 0x832);
	avis_wr(saa7231, 0x1004, 0x2a000104);

	/* FUN_00022b50 tail: engine enable.  The Windows reference shows
	 * 0x1801090 while capturing, not 0x2a01090 as our old flag guess. */
	aud_wr(saa7231, 0x1d0, 0x1801090);
}

/* one buffer of statistics is enough to tell PCM from silence */
static void saa7231_audio_report(struct saa7231_audio *a, u32 index)
{
	const s16 *p = a->stream->ring->dmabuf[index].virt;
	u32 i, n = AUD_SIZE / sizeof(s16), nonzero = 0;
	s32 min = 32767, max = -32768;
	u64 sum = 0;

	for (i = 0; i < n; i++) {
		s32 v = p[i];

		if (v < min)
			min = v;
		if (v > max)
			max = v;
		if (v)
			nonzero++;
		sum += (u64)(v * v);
	}
	pr_info("saa7231 audio: buf %u min=%d max=%d rms=%u nonzero=%u/%u\n",
		index, min, max, (u32)int_sqrt64(sum / n), nonzero, n);
}

static int saa7231_audio_thread(void *data)
{
	struct saa7231_audio *a = data;
	u32 index, fid, last = ~0;

	while (!kthread_should_stop()) {
		if (!a->stream->ops.get_buffer(a->stream, &index, &fid) &&
		    index != last) {
			if (last < XS2D_BUFFERS)
				saa7231_audio_report(a, last);
			last = index;
			a->buffers++;
		}
		msleep(20);
	}
	return 0;
}

int saa7231_audio_start(struct saa7231_dev *saa7231)
{
	struct saa7231_audio *a;
	struct saa7231_stream *stream;
	int ret;

	if (!audio_init)
		return 0;
	if (audio_state)
		return -EBUSY;

	a = kzalloc(sizeof(*a), GFP_KERNEL);
	if (!a)
		return -ENOMEM;
	a->saa7231 = saa7231;

	stream = saa7231_stream_init(saa7231, AUDIO_CAPTURE, ADAPTER_INT, 0,
				     CALC_PAGES(AUD_PITCH, AUD_LINES));
	if (!stream) {
		kfree(a);
		return -ENOMEM;
	}
	stream->config		= audio_config;

	stream->params.bps	= AUD_BPS;
	stream->params.spl	= AUD_CH;
	stream->params.pitch	= AUD_PITCH;
	stream->params.lines	= AUD_LINES;
	stream->params.flags	= 0;
	stream->params.type	= STREAM_AUDIO;
	stream->params.size	= AUD_SIZE;

	ret = stream->ops.acquire(stream);
	if (ret)
		goto err;

	saa7231_audio_program(saa7231);

	ret = stream->ops.run(stream);
	if (ret)
		goto err;

	a->stream = stream;
	audio_state = a;
	a->thread = kthread_run(saa7231_audio_thread, a, "saa7231-audio");
	if (IS_ERR(a->thread)) {
		a->thread = NULL;
		ret = -ENOMEM;
		goto err;
	}
	pr_info("saa7231 audio: streaming %u Hz\n",
		audio_rate == 1 ? 44100 : (audio_rate == 2 ? 48000 : 32000));
	return 0;
err:
	saa7231_stream_exit(stream);
	kfree(a);
	return ret;
}

void saa7231_audio_stop(struct saa7231_dev *saa7231)
{
	struct saa7231_audio *a = audio_state;

	if (!a)
		return;

	if (a->thread) {
		kthread_stop(a->thread);
		a->thread = NULL;
	}
	a->stream->ops.pause(a->stream);
	a->stream->ops.stop(a->stream);
	saa7231_stream_exit(a->stream);
	pr_info("saa7231 audio: stop, %u buffers\n", a->buffers);
	audio_state = NULL;
	kfree(a);
}
