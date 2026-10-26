#!/usr/bin/env python3
"""Generates the placeholder cover images and audio tracks the local
Supabase storage serves for the seeded songs."""

import math
import os
import struct
import sys
import wave
import zlib


def write_png(path, width, height, rgb):
    """Writes a solid colour PNG (no third-party imaging library needed)."""
    raw = b''
    for _ in range(height):
        raw += b'\x00' + bytes(rgb) * width

    def chunk(tag, data):
        payload = tag + data
        return (
            struct.pack('>I', len(data))
            + payload
            + struct.pack('>I', zlib.crc32(payload) & 0xFFFFFFFF)
        )

    header = struct.pack('>2I5B', width, height, 8, 2, 0, 0, 0)
    png = (
        b'\x89PNG\r\n\x1a\n'
        + chunk(b'IHDR', header)
        + chunk(b'IDAT', zlib.compress(raw, 9))
        + chunk(b'IEND', b'')
    )
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as handle:
        handle.write(png)


def write_wav(path, frequency, seconds=2.0, rate=22050):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    frames = bytearray()
    total = int(rate * seconds)
    for index in range(total):
        # Simple fade in/out so the track does not click.
        envelope = min(1.0, index / 1000, (total - index) / 1000)
        value = int(12000 * envelope * math.sin(2 * math.pi * frequency * index / rate))
        frames += struct.pack('<h', value)
    with wave.open(path, 'wb') as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        handle.writeframes(bytes(frames))


def main():
    storage_root = sys.argv[1]
    covers = [
        ('cover-1.png', (34, 197, 94)),
        ('cover-2.png', (59, 130, 246)),
        ('cover-3.png', (244, 63, 94)),
    ]
    tracks = [('track-1.wav', 220.0), ('track-2.wav', 277.18), ('track-3.wav', 329.63)]

    for name, rgb in covers:
        write_png(os.path.join(storage_root, 'images', 'seed', name), 512, 512, rgb)
    for name, frequency in tracks:
        write_wav(os.path.join(storage_root, 'songs', 'seed', name), frequency)


if __name__ == '__main__':
    main()
