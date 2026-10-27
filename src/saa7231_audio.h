#ifndef __SAA7231_AUDIO_H__
#define __SAA7231_AUDIO_H__

struct saa7231_dev;

int saa7231_audio_start(struct saa7231_dev *saa7231);
void saa7231_audio_stop(struct saa7231_dev *saa7231);

#endif
