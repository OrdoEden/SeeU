#!/usr/bin/env python3
"""Numerical model of ImageAligner, not a Swift execution or build.

Requires existing numpy and Pillow. Reads local images only; writes no image data.
Example: python verify_image_alignment.py previous.png current.png --region 0 300 1179 1985
"""
import argparse
from collections import Counter
import json
import time

import numpy as np
from PIL import Image


def positions(start, end, count):
    if start > end:
        return np.array([], dtype=int)
    return np.unique(np.arange(count) * (end - start) // (count - 1) + start)


def mask_for(image, region, exclusions):
    height, width = image.shape[:2]
    x, y, w, h = region or (0, 0, width, height)
    if not np.isfinite([x, y, w, h]).all() or w <= 0 or h <= 0:
        raise ValueError("invalid region")
    bounds = (max(0, x), max(0, y), min(width, x + w), min(height, y + h))
    yy, xx = np.mgrid[:height, :width]
    mask = (xx >= bounds[0]) & (yy >= bounds[1]) & (xx < bounds[2]) & (yy < bounds[3])
    for x, y, w, h in exclusions:
        mask &= ~((xx >= x) & (yy >= y) & (xx < x + w) & (yy < y + h))
    return bounds, mask


def align(previous, current, region=None, current_exclusions=()):
    started = time.perf_counter()
    if previous.shape[1] != current.shape[1]:
        return {"status": "unmatched", "reason": "differentWidths"}
    a_bounds, a_mask = mask_for(previous, region, ())
    b_bounds, b_mask = mask_for(current, region, current_exclusions)
    a = previous @ np.array([.299, .587, .114])
    b = current @ np.array([.299, .587, .114])
    radius = max(4, min(32, int(current.shape[1] * .022 + .5)))
    left = int(np.ceil(max(a_bounds[0], b_bounds[0])))
    right = int(np.floor(min(a_bounds[2], b_bounds[2])))
    xs = positions(left + radius, right - radius - 1, 10)
    ys = positions(int(np.ceil(b_bounds[1])) + radius, int(np.floor(b_bounds[3])) - radius - 1, 48)
    candidates = np.arange(int(np.ceil(a_bounds[1])) + radius, int(np.floor(a_bounds[3])) - radius)
    grid, dense = positions(-radius, radius, 5), positions(-radius, radius, 9)
    votes, searched = [], 0
    for y in ys:
        for x in xs:
            xx, yy = np.meshgrid(x + grid, y + grid)
            xx, yy = xx.flatten(), yy.flatten()
            valid = b_mask[yy, xx]
            same_valid = yy < a.shape[0]
            same_valid[same_valid] &= a_mask[yy[same_valid], xx[same_valid]]
            changed = ~same_valid
            changed[same_valid] |= abs(b[yy[same_valid], xx[same_valid]] - a[yy[same_valid], xx[same_valid]]) > 12
            valid &= changed
            xx, yy = xx[valid], yy[valid]
            values = b[yy, xx]
            if len(values) < 8 or values.var() < 256 or not len(candidates):
                continue
            searched += 1
            target_y = candidates[:, None] + (yy - y)[None, :]
            costs = abs(a[target_y, xx[None, :]] - values).mean(axis=1)
            costs[~a_mask[target_y, xx[None, :]].all(axis=1)] = 18
            best_index = costs.argmin()
            best_y, best_error = candidates[best_index], costs[best_index]
            if best_error >= 8 or best_y == y:
                continue
            costs[abs(candidates - best_y) <= 3] = 18
            if costs.min() <= best_error * 1.5 + 2:
                continue
            offset = best_y - y
            xx, yy = np.meshgrid(x + dense, y + dense)
            xx, yy = xx.flatten(), yy.flatten()
            valid = b_mask[yy, xx] & a_mask[yy + offset, xx]
            same_valid = yy < a.shape[0]
            same_valid[same_valid] &= a_mask[yy[same_valid], xx[same_valid]]
            changed = ~same_valid
            changed[same_valid] |= abs(b[yy[same_valid], xx[same_valid]] - a[yy[same_valid], xx[same_valid]]) > 12
            valid &= changed
            xx, yy = xx[valid], yy[valid]
            if len(xx) < 12:
                continue
            error = abs(current[yy, xx] - previous[yy + offset, xx]).mean()
            if error < 10:
                votes.append((int(offset), int(y), float(error)))
    groups = [list(filter(lambda v: abs(v[0] - offset) <= 1, votes)) for offset in sorted(set(v[0] for v in votes))]
    groups.sort(key=lambda g: (-len(g), sum(v[2] for v in g), g[0][0]))
    result = {"status": "unmatched", "searched_blocks": searched,
              "clusters": Counter(v[0] for v in votes).most_common(8),
              "model_seconds": round(time.perf_counter() - started, 3)}
    if groups:
        best = groups[0]
        offset = sorted(v[0] for v in best)[len(best) // 2]
        rows = [v[1] for v in best]
        rival = next((g for g in groups if abs(g[0][0] - offset) > 3), [])
        if len(best) >= 3 and len(set(rows)) >= 2 and max(rows) - min(rows) >= 2 * radius and len(rival) < .7 * len(best):
            result.update(status="matched", offset=offset, matched_regions=len(best), matching_range=[min(rows), max(rows)])
    # Swift's unchanged gate uses the same 32x80 RGB samples before block search.
    if a_bounds == b_bounds:
        points = [(int(a_bounds[0] + (col + .5) * (a_bounds[2] - a_bounds[0]) / 32),
                   int(a_bounds[1] + (row + .5) * (a_bounds[3] - a_bounds[1]) / 80))
                  for row in range(80) for col in range(32)]
        errors = [abs(previous[y, x] - current[y, x]).mean() for x, y in points if a_mask[y, x] and b_mask[y, x]]
        if len(errors) >= 128 and np.mean(errors) <= 2 and np.mean(np.array(errors) > 12) < .004:
            result.update(status="unchanged", offset=0)
    return result


def synthetic(scroll=0, seed=17, repeating=False):
    y, x = np.mgrid[:520, :240].astype(np.uint64)

    def texture(xx, yy, s):
        value = (xx + 1) * 73856093 ^ (yy + 1) * 19349663 ^ np.uint64(s) * np.uint64(83492791)
        return (value ^ (value >> 13) ^ (value >> 23)) & 255

    content_y = (y + scroll) % 64 if repeating else y + scroll
    values = np.where((x >= 60) & (x < 150), texture(x, content_y, seed), texture(x, y, 3)).astype(float)
    return np.repeat(values[:, :, None], 3, axis=2)


def self_check():
    previous, current = synthetic(), synthetic(173)
    assert align(previous, current)["offset"] == 173
    assert align(current, previous)["offset"] == -173
    assert align(previous, previous)["status"] == "unchanged"
    assert align(previous, synthetic(seed=871))["status"] == "unmatched"
    assert align(synthetic(repeating=True), synthetic(31, repeating=True))["status"] == "unmatched"
    overlay = current.copy()
    overlay[40:130, 45:200] = [245, 30, 60]
    assert align(previous, overlay, [0, 30, 240, 460], [[45, 40, 155, 90]])["offset"] == 173
    print("Synthetic numerical checks passed; Swift/XCTest were not run.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("previous", nargs="?")
    parser.add_argument("current", nargs="?")
    parser.add_argument("--region", nargs=4, type=float, metavar=("X", "Y", "WIDTH", "HEIGHT"))
    parser.add_argument("--self-check", action="store_true")
    args = parser.parse_args()
    if args.self_check:
        self_check()
    if args.previous and args.current:
        first = np.asarray(Image.open(args.previous).convert("RGB"), dtype=float)
        second = np.asarray(Image.open(args.current).convert("RGB"), dtype=float)
        print(json.dumps({"forward": align(first, second, args.region),
                          "reverse": align(second, first, args.region)}, indent=2))
    elif not args.self_check:
        parser.error("provide both images or --self-check")
