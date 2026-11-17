#!/usr/bin/env python3
"""Summarize pass instrumentation; optionally gate a candidate against a baseline.

usage: race_metrics.py PREFIX [BASELINE_PREFIX]
The gate needs >=240 passes, matching replay policy, useful progress, and no
regression in long-window throughput or median/p95/worst pass/flip latency.
"""
import csv
import json
import math
from pathlib import Path
import statistics
import sys


def rows(prefix, suffix):
    with open(prefix + suffix) as source:
        return list(csv.DictReader(source))


def latency(values):
    values = sorted(values)
    if not values:
        raise ValueError('No latency observations')
    return dict(median=statistics.median(values),
                p95=values[math.ceil(.95 * len(values)) - 1], worst=values[-1])


def window(data):
    seconds = sum(float(r['seconds']) for r in data)
    totals = {k: sum(float(r[k]) for r in data) for k in (
        'renders', 'render_s', 'render_cpu_s', 'irq_s', 'irq_context_s', 'irqs',
        'cells', 'commands', 'lmmc', 'lmmv', 'lmmm', 'cmmc', 'other', 'copy_pixels',
        'captures', 'capture_bytes', 'local_records', 'local_bytes', 'recovery_calls', 'collision_contacts')}
    return dict(passes=len(data), seconds=seconds, passes_per_second=len(data)/seconds,
                pass_latency_s=latency([float(r['seconds']) for r in data]), **totals)


def summarize(prefix):
    metadata = json.loads(Path(prefix + '_metadata.json').read_text())
    data = rows(prefix, '_passes.csv')
    frames = rows(prefix, '_frames.csv')
    if len(data) != len(frames) or any(
        int(a['pass']) != i or abs(float(a['seconds'])-float(b['seconds'])) > 1e-9
        for i, (a, b) in enumerate(zip(data, frames), 1)
    ):
        raise ValueError('Profiler intervals do not match race-loop intervals')
    for r in data:
        if abs(sum(float(r[k]) for k in ('lmmc', 'lmmv', 'lmmm', 'cmmc', 'other')) - float(r['commands'])) > 0:
            raise ValueError('Command type accounting mismatch')
        if float(r['render_cpu_s']) + float(r['irq_s']) > float(r['seconds']) + 1e-9:
            raise ValueError('Renderer/IRQ time double counted')
    flips = [float(r['seconds']) for r in rows(prefix, '_flips.csv')]
    renders = rows(prefix, '_renders.csv')
    events = rows(prefix, '_events.csv')
    # This is a speed-dependent world-step counter ($006A:$006B), not metres.
    progress = [int(r['progress']) for r in data]
    increments = [(b-a) & 65535 for a, b in zip(progress, progress[1:])]
    progress_valid = all(n < 128 for n in increments)
    total_steps = sum(increments) if progress_valid else None
    scenario = metadata['scenario']
    collision = next((int(e['pass']) for e in events if e['event'] in ('collision_recovery', 'collision_contact')), None)
    impact = next((r for r in data if collision is not None and int(r['pass']) >= collision
                   and (int(r['impact']) or int(r['recovery']))), None)
    recovered = impact is not None and any(
        int(r['pass']) > int(impact['pass']) and int(r['recovery']) == 0 and int(r['impact']) == 0
        and int(r['velocity']) > 0 and 0 < ((int(r['progress'])-int(impact['progress'])) & 65535) < 32768
        for r in data)
    steering_responses = {}
    for name, mask, intervals in (('left', 4, ((19, 29), (69, 79))),
                                  ('right', 8, ((29, 49), (79, 99)))):
        steering_responses[name] = next((int(r['pass']) for start, end in intervals
            for r in data[start:end] if int(r['joy']) & mask == 0
            and (int(r['steer']) < 6 if mask == 4 else int(r['steer']) > 6)
            and int(r['car_x']) != int(data[start-1]['car_x'])), None)
    steering_ok = scenario != 'steering' or all(steering_responses.values())
    result = dict(metadata=metadata, long=window(data), windows={},
                  flip_latency_s=latency([b-a for a, b in zip(flips, flips[1:])]),
                  render_latency_s=latency([float(r['seconds']) for r in renders]),
                  progress=dict(first=progress[0], last=progress[-1], steps=total_steps,
                                steps_per_second=total_steps/sum(float(r['seconds']) for r in data)
                                if total_steps is not None else None,
                                valid=progress_valid, moving_passes=sum(int(r['velocity']) > 0 for r in data)),
                  scenarios=dict(steering_response=steering_ok, collision_pass=collision,
                                 collision_recovered=recovered, steering_response_passes=steering_responses))
    for start, end in ((1, 120), (121, 160), (161, 240), (121, 240)):
        subset = [r for r in data if start <= int(r['pass']) <= end]
        if subset:
            result['windows'][f'{start}-{end}'] = window(subset)
    complete = 'status=complete' in Path(prefix + '_result.txt').read_text()
    result['measurement_valid'] = complete and len(data) >= 240 and progress_valid and bool(total_steps) and steering_ok and (
        scenario != 'collision' or recovered)
    return result


def gate(candidate, baseline):
    reasons = []
    if candidate['metadata'].get('course', 0) != baseline['metadata'].get('course', 0):
        reasons.append('Unmatched metadata: course')
    for name, result in (('candidate', candidate), ('baseline', baseline)):
        if not result['measurement_valid']:
            reasons.append(f'{name}: incomplete window, progress, or scenario evidence')
    for key in ('scenario', 'config', 'passes', 'profile', 'validation', 'metrics'):
        if candidate['metadata'][key] != baseline['metadata'][key]:
            reasons.append(f'Unmatched metadata: {key}')
    if candidate['long']['passes_per_second'] < baseline['long']['passes_per_second']:
        reasons.append('Long-window throughput regressed')
    if '121-240' in candidate['windows'] and '121-240' in baseline['windows'] and (
        candidate['windows']['121-240']['passes_per_second'] < baseline['windows']['121-240']['passes_per_second']
    ):
        reasons.append('Late-window throughput regressed')
    for group in ('pass_latency_s', 'flip_latency_s', 'render_latency_s'):
        a = candidate['long'][group] if group == 'pass_latency_s' else candidate[group]
        b = baseline['long'][group] if group == 'pass_latency_s' else baseline[group]
        for statistic in ('median', 'p95', 'worst'):
            if a[statistic] > b[statistic] + 1e-9:
                reasons.append(f'{group}/{statistic} regressed')
    if candidate['progress']['valid'] and baseline['progress']['valid'] and (
        candidate['progress']['steps_per_second'] < baseline['progress']['steps_per_second']
    ):
        reasons.append('Useful world steps per second regressed')
    return dict(accepted=not reasons, reasons=reasons)


if __name__ == '__main__':
    prefix = sys.argv[1]
    report = summarize(prefix)
    if len(sys.argv) > 2:
        report['gate'] = gate(report, summarize(sys.argv[2]))
    Path(prefix + '_metrics.json').write_text(json.dumps(report, indent=2) + '\n')
    for name, w in [('long', report['long']), *report['windows'].items()]:
        p = w['pass_latency_s']
        print('%s: %.3fs, %.3f passes/s; pass median/p95/worst %.2f/%.2f/%.2fms; '
              'render %.3fs, IRQ %.3fs, cells %d, commands %d, timeline bytes %d/%d' % (
                  name, w['seconds'], w['passes_per_second'], p['median']*1000,
                  p['p95']*1000, p['worst']*1000, w['render_s'], w['irq_s'],
                  w['cells'], w['commands'], w['capture_bytes'], w['local_bytes']))
    print('Progress:', report['progress'], 'Scenarios:', report['scenarios'])
    print('Measurement valid:', report['measurement_valid'])
    if 'gate' in report:
        print('Gate:', report['gate'])
        sys.exit(0 if report['gate']['accepted'] else 1)
