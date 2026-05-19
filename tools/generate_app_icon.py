"""Hypnoctone App Icon 生成スクリプト.

1024x1024 の iOS App Icon master を 1 枚出力する。Xcode 14+ の
single-size AppIcon 機能でこの 1 枚から全 size が自動生成されるため、
ここで作るのはこのファイルだけで足りる。

要件:
- Pillow / numpy
- Theme.swift と同じ配色 (Theme.backgroundTop / backgroundBottom / accent)
- 完全不透明 (Apple App Icon guideline)
- 角丸を入れない (iOS が自動で角丸マスクをかける)
- 文字を入れない (アプリ名は OS が表示する)
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image

SIZE = 1024

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_PATH = (
    REPO_ROOT
    / "HypnoctoneEngine"
    / "Assets.xcassets"
    / "AppIcon.appiconset"
    / "icon-1024.png"
)

BG_TOP = np.array([13, 15, 31], dtype=np.float32)
BG_BOTTOM = np.array([5, 5, 13], dtype=np.float32)
ACCENT = np.array([107, 102, 184], dtype=np.float32)

R_HALO = SIZE * 0.42
R_CORE = SIZE * 0.30
HALO_PEAK_ALPHA = 0.18
CORE_PEAK_ALPHA = 0.78


def vertical_gradient() -> np.ndarray:
    t = np.linspace(0.0, 1.0, SIZE, dtype=np.float32).reshape(SIZE, 1, 1)
    gradient_column = BG_TOP * (1.0 - t) + BG_BOTTOM * t
    return np.broadcast_to(gradient_column, (SIZE, SIZE, 3)).copy()


def radial_alpha() -> np.ndarray:
    cx = cy = (SIZE - 1) / 2.0
    yy, xx = np.indices((SIZE, SIZE), dtype=np.float32)
    d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)

    halo_falloff = np.clip(1.0 - d / R_HALO, 0.0, 1.0)
    halo_alpha = (halo_falloff ** 2) * HALO_PEAK_ALPHA

    core_falloff = np.clip(1.0 - d / R_CORE, 0.0, 1.0)
    core_alpha = (core_falloff ** 1.6) * CORE_PEAK_ALPHA

    return np.clip(halo_alpha + core_alpha, 0.0, 1.0)


def composite_accent(background: np.ndarray, alpha: np.ndarray) -> np.ndarray:
    alpha_3 = alpha[..., None]
    return background * (1.0 - alpha_3) + ACCENT * alpha_3


def main() -> None:
    background = vertical_gradient()
    alpha = radial_alpha()
    rgb = composite_accent(background, alpha)
    rgb_u8 = np.clip(rgb, 0.0, 255.0).astype(np.uint8)

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(rgb_u8, mode="RGB").save(OUTPUT_PATH, format="PNG", optimize=True)
    print(f"wrote {OUTPUT_PATH} ({SIZE}x{SIZE} RGB PNG)")


if __name__ == "__main__":
    main()
