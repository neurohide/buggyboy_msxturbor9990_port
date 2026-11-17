#!/usr/bin/env python3
"""Gate live control coverage and summarize recorded PCM and emulator cadence."""
import array
import csv
import hashlib
import json
import math
import re
from pathlib import Path
import statistics
import sys
import wave


def read_csv(path):
    with open(path) as source:
        return list(csv.DictReader(source))


def latency(values):
    values = sorted(values)
    if not values:
        raise ValueError('No cadence observations')
    return dict(median=statistics.median(values), p95=values[math.ceil(.95*len(values))-1],
                worst=values[-1], count=len(values))


def summarize(prefix, audio):
    metadata = json.loads(Path(prefix+'_metadata.json').read_text())
    mode = 1 if audio else 2
    if not re.search(rf'IRQ_NATIVE_MODE:\s*equ\s+{mode}\b', metadata['config']):
        raise ValueError(f'{prefix}: wrong ROM mode')
    status = Path(prefix+'_result.txt').read_text()
    requested = metadata['passes']
    minimum = 240 if metadata.get('course', 0) == 0 else 160
    if 'status=complete' not in status or (audio and (
            requested < minimum or status.splitlines()[0] != f'status=complete passes={requested}')):
        raise ValueError(f'{prefix}: incomplete replay')
    events = read_csv(prefix+'_live.csv')
    by_name = {row['event']: row for row in events}
    required = ('left', 'right', 'pause_down', 'pause_release', 'paused',
                'resume_down', 'resume_release', 'resumed', 'finished')
    if tuple(by_name) != required:
        raise ValueError(f'{prefix}: incomplete or out-of-order live scenario')
    left, right = by_name['right'], by_name['pause_down']
    if (int(left['joy']) & 4 or int(left['steer']) >= 6 or int(left['x']) >= int(by_name['left']['x'])
            or int(right['joy']) & 8 or int(right['steer']) <= 6 or int(right['x']) <= int(left['x'])):
        raise ValueError(f'{prefix}: steering input did not move the car in both directions')
    for name, phase, key in (('pause_release', 1, 127), ('paused', 2, 255),
                              ('resume_down', 2, 255), ('resume_release', 224, 127),
                              ('resumed', 0, 255)):
        if int(by_name[name]['phase']) != phase or int(by_name[name]['key']) != key:
            raise ValueError(f'{prefix}: missing actual STOP transition at {name}')
    paused, held, resumed = (by_name[k] for k in ('paused', 'resume_down', 'resumed'))
    if (int(held['tick'])-int(paused['tick']) < 30 or paused['progress'] != held['progress']
            or int(paused['velocity']) or int(held['velocity'])
            or int(resumed['velocity']) <= 0 or resumed['progress'] == paused['progress']):
        raise ValueError(f'{prefix}: pause/resume invariant failed')
    if not all(int(held[k]) > int(paused[k]) for k in ('audio', 'inputs')):
        raise ValueError(f'{prefix}: audio/input stopped while paused')
    log = Path(prefix+'.log').read_text()
    if 'FAILED' in log or 'Live IRQ verification passed:' not in log:
        raise ValueError(f'{prefix}: missing success or failed emulator assertion')
    cadence = read_csv(prefix+'_cadence.csv')
    intervals = [float(row['interval']) for row in cadence if row['interval']]
    # Counter wrap is intentional; each sampled synthesis call must be next vblank.
    if any((int(b['frame'])-int(a['frame'])) & 255 != 1 for a, b in zip(cadence, cadence[1:])):
        raise ValueError(f'{prefix}: missing or duplicate audio dispatch')
    if not all(0 < n < .1 for n in intervals):
        raise ValueError(f'{prefix}: non-monotonic or >100ms audio dispatch gap')
    seconds = float(events[-1]['time'])-float(events[0]['time'])
    result = dict(metadata=metadata, events=events, cadence_s=latency(intervals),
                  audio_calls=len(cadence), audio_hz=len(cadence)/seconds,
                  paused_seconds=float(held['time'])-float(paused['time']))
    if audio:
        psg = [bytes.fromhex(row['psg']) for row in cadence]
        active = sum(any(registers[8+voice] & 31 and
                         (registers[7] & (1 << voice) == 0 or registers[7] & (8 << voice) == 0)
                         for voice in range(3)) for registers in psg)
        if not active:
            raise ValueError(f'{prefix}: PSG never enabled a voice with volume')
        result['active_psg_frames'] = active
        filename = prefix+'_audio.wav'
        with wave.open(filename) as source:
            params = source.getparams()
            if params.sampwidth != 2:
                raise ValueError('Expected signed 16-bit PCM')
            samples = array.array('h', source.readframes(params.nframes))
        if sys.byteorder != 'little':
            samples.byteswap()
        peak = max(abs(n) for n in samples)
        rms = math.sqrt(sum(n*n for n in samples)/len(samples))
        clipped = sum(n in (-32768, 32767) for n in samples)
        if peak == 0 or rms == 0 or clipped:
            raise ValueError(f'{prefix}: silent or saturated PCM recording')
        pcm_seconds = params.nframes/params.framerate
        if abs(pcm_seconds-seconds) > .05:
            raise ValueError(f'{prefix}: audio duration differs from replay')
        result['pcm'] = dict(path=filename, sha256=hashlib.sha256(Path(filename).read_bytes()).hexdigest(),
                             seconds=pcm_seconds, sample_rate=params.framerate, channels=params.nchannels,
                             peak=peak, rms=rms, saturated_samples=clipped)
        # Export short clips for human listening; numeric checks cannot judge sound quality.
        for name, event, length in (('engine', by_name['right'], 1), ('pause', paused, 1),
                                    ('resume', resumed, 3)):
            start = max(0, float(event['time'])-float(events[0]['time']))
            lo = int(start*params.framerate)*params.nchannels
            hi = min(len(samples), lo+int(length*params.framerate)*params.nchannels)
            clip = samples[lo:hi]
            if sys.byteorder != 'little':
                clip.byteswap()
            with wave.open(prefix+'_'+name+'.wav', 'wb') as target:
                target.setparams(params)
                target.writeframes(clip.tobytes())
    else:
        match = re.search(r'IRQ differential counts: (.*?) synthetic=0 snapshots=(\d+)', log)
        if not match:
            raise ValueError(f'{prefix}: missing differential summary')
        values = match[1].split()
        counts = {values[i]: int(values[i+1]) for i in range(0, len(values), 2)}
        if set(counts) != {'10E3', '11C5', '134C', '141A'} or min(counts.values()) < 1000 or int(match[2]) <= 0:
            raise ValueError(f'{prefix}: incomplete differential coverage')
        result.update(handler_comparisons=counts, snapshots=int(match[2]))
    return result


def main():
    out = sys.argv[1]
    courses = [int(n) for n in sys.argv[2:]] or list(range(5))
    report = dict(courses={}, audible_listening='pending human review', real_hardware_timing='not measured')
    for course in courses:
        report['courses'][course] = {mode: summarize(f'{out}_{mode}_c{course}', mode == 'native')
                                     for mode in ('ab', 'native')}
        if any(result['metadata']['course'] != course for result in report['courses'][course].values()):
            raise ValueError(f'Course {course}: replay metadata does not match requested course')
    Path(out+'_verification.json').write_text(json.dumps(report, indent=2)+'\n')
    print(f'Live IRQ matrix passed: courses {courses}; PCM/cadence checked; listening and physical timing pending')


if __name__ == '__main__':
    main()
