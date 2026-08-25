#!/usr/bin/env python3
"""Persistent local Canary MLX bridge for Parrot.

The Swift process owns recording, Fn gestures and text injection. This small
line-oriented worker owns the MLX model so it is loaded exactly once and never
shares stdout with diagnostics. It accepts only 16 kHz mono PCM WAV files
written by Parrot itself.
"""

import argparse
import json
import sys
import time
import wave

import numpy as np
from mlx_audio.stt.utils import load


def emit(payload):
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def load_wav(path):
    with wave.open(path, "rb") as input_wav:
        if input_wav.getsampwidth() != 2 or input_wav.getnchannels() != 1:
            raise ValueError("Parrot expects a 16-bit mono WAV capture")
        if input_wav.getframerate() != 16_000:
            raise ValueError("Parrot expects a 16 kHz WAV capture")
        pcm = np.frombuffer(input_wav.readframes(input_wav.getnframes()), dtype="<i2")
    return pcm.astype(np.float32) / 32768.0


def transcribe(model, audio):
    # Canary's current MLX conversion can loop on long, difficult recordings.
    # Fixed 30-second windows keep each greedy decode bounded while remaining
    # far longer than ordinary Fn dictations.
    chunk_samples = 30 * 16_000
    chunks = []
    for start in range(0, len(audio), chunk_samples):
        result = model.generate(
            audio[start : start + chunk_samples],
            source_lang="fr",
            target_lang="fr",
            use_pnc=True,
            max_tokens=200,
        )
        text = result.text.strip()
        if text:
            chunks.append(text)
    return " ".join(chunks)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    arguments = parser.parse_args()

    started = time.perf_counter()
    model = load(arguments.model)
    emit({"event": "ready", "seconds": time.perf_counter() - started})

    for raw_request in sys.stdin:
        request = {}
        try:
            request = json.loads(raw_request)
            request_id = request["id"]
            audio_path = request["audioPath"]
            emit({"id": request_id, "text": transcribe(model, load_wav(audio_path))})
        except Exception as error:
            print(f"canary worker error: {error}", file=sys.stderr, flush=True)
            emit({"id": request.get("id"), "error": str(error)})


if __name__ == "__main__":
    main()
