#!/usr/bin/env python3
"""JSON-lines bridge between VoiceInk and mlx-qwen3-asr.

The process stays resident so the MLX model and decoder weights remain loaded.
Audio is fed incrementally to mlx-qwen3-asr's StreamingState; it is never
re-decoded through VoiceInk's sliding-window preview implementation.
"""

from __future__ import annotations

import base64
import json
import sys
import traceback
from importlib.metadata import version

import mlx.core as mx
import numpy as np
from mlx_qwen3_asr import Session
from mlx_qwen3_asr.streaming import streaming_metrics


session: Session | None = None
stream_state = None
model_path: str | None = None


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def require_session() -> Session:
    if session is None:
        raise RuntimeError("Qwen MLX model is not loaded")
    return session


def clean_language(value):
    if value is None:
        return None
    value = str(value).strip()
    if not value or value.casefold() == "auto":
        return None
    return value


def snapshot_payload(state) -> dict:
    return {
        "text": state.text,
        "stable_text": state.stable_text,
        "language": state.language,
        "metrics": streaming_metrics(state),
    }


def handle(message: dict) -> tuple[dict, bool]:
    global session, stream_state, model_path

    command = message.get("command")
    if command == "load":
        requested_path = str(message["model_path"])
        mx.set_default_device(mx.gpu)
        if session is None or model_path != requested_path:
            session = Session(requested_path, dtype=mx.float16)
            model_path = requested_path
        stream_state = None
        return {
            "backend": str(mx.default_device()),
            "runtime_version": version("mlx-qwen3-asr"),
            "model": session.model_info,
        }, False

    if command == "start":
        active_session = require_session()
        if stream_state is not None:
            raise RuntimeError("A streaming session is already active")
        stream_state = active_session.init_streaming(
            context=str(message.get("context") or ""),
            language=clean_language(message.get("language")),
            chunk_size_sec=float(message.get("chunk_size_sec", 1.0)),
            max_context_sec=float(message.get("max_context_sec", 30.0)),
            finalization_mode=str(message.get("finalization_mode", "accuracy")),
            endpointing_mode=str(message.get("endpointing_mode", "energy")),
        )
        return snapshot_payload(stream_state), False

    if command == "audio":
        active_session = require_session()
        if stream_state is None:
            raise RuntimeError("No streaming session is active")
        raw = base64.b64decode(message.get("pcm16_base64", ""), validate=True)
        if len(raw) % 2 != 0:
            raise ValueError("PCM16 payload has an odd byte count")
        pcm = np.frombuffer(raw, dtype="<i2")
        stream_state = active_session.feed_audio(pcm, stream_state)
        return snapshot_payload(stream_state), False

    if command == "finish":
        active_session = require_session()
        if stream_state is None:
            raise RuntimeError("No streaming session is active")
        stream_state = active_session.finish_streaming(stream_state)
        payload = snapshot_payload(stream_state)
        stream_state = None
        return payload, False

    if command == "cancel":
        stream_state = None
        return {}, False

    if command == "transcribe":
        active_session = require_session()
        if stream_state is not None:
            raise RuntimeError("Cannot batch-transcribe during an active stream")
        result = active_session.transcribe(
            str(message["audio_path"]),
            context=str(message.get("context") or ""),
            language=clean_language(message.get("language")),
            verbose=False,
        )
        return {"text": result.text, "language": result.language}, False

    if command == "shutdown":
        stream_state = None
        return {}, True

    raise ValueError(f"Unsupported command: {command}")


def main() -> int:
    for line in sys.stdin:
        request_id = None
        try:
            message = json.loads(line)
            request_id = message.get("id")
            payload, should_exit = handle(message)
            emit({"id": request_id, "ok": True, **payload})
            if should_exit:
                return 0
        except Exception as exc:
            traceback.print_exc(file=sys.stderr)
            emit({
                "id": request_id,
                "ok": False,
                "error": str(exc),
                "error_type": type(exc).__name__,
            })
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
