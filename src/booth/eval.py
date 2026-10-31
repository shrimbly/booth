"""Compare two audio files: loudness, SI-SDR, and octave-band spectral deltas."""

from __future__ import annotations

from pathlib import Path

import numpy as np

from . import audio as A
from . import dsp

BANDS = [63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]


def band_energies_db(x: np.ndarray, sr: int) -> dict[int, float]:
    spec_f, spec_p = dsp.active_spectrum(x, sr)
    out = {}
    for f0 in BANDS:
        lo, hi = f0 / 2 ** 0.5, f0 * 2 ** 0.5
        sel = (spec_f >= lo) & (spec_f < hi)
        out[f0] = float(10 * np.log10(spec_p[sel].mean() + 1e-20)) if sel.any() else float("nan")
    return out


def compare(ref_path: Path, test_path: Path) -> dict:
    ref = A.decode(ref_path)
    test = A.decode(test_path)
    lag, test = dsp.align(ref, test)
    n = min(len(ref), len(test))
    ref, test = ref[:n], test[:n]

    res = {
        "lag_samples": lag,
        "si_sdr_db": dsp.si_sdr(test, ref),
        "lufs_ref": A.integrated_lufs(ref_path),
        "lufs_test": A.integrated_lufs(test_path),
        "bands": {},
    }
    try:
        from . import mos
        res["mos_ref"] = mos.score(ref)
        res["mos_test"] = mos.score(test)
    except Exception:
        pass  # onnxruntime unavailable or download failed — skip MOS
    eb_ref = band_energies_db(ref, A.SR)
    eb_test = band_energies_db(test, A.SR)
    for f0 in BANDS:
        res["bands"][f0] = eb_test[f0] - eb_ref[f0]
    return res


def print_report(res: dict, ref_name: str, test_name: str, console=None) -> None:
    from rich.console import Console
    from rich.table import Table
    console = console or Console()
    console.print(f"[bold]reference:[/bold] {ref_name}")
    console.print(f"[bold]test:     [/bold] {test_name}")
    console.print(f"alignment lag: {res['lag_samples']} samples")
    console.print(f"SI-SDR (test vs ref): [bold]{res['si_sdr_db']:.2f} dB[/bold]")
    console.print(f"LUFS: ref {res['lufs_ref']:.1f}  test {res['lufs_test']:.1f}  "
                  f"(Δ {res['lufs_test'] - res['lufs_ref']:+.1f})")
    if "mos_ref" in res:
        mr, mt = res["mos_ref"], res["mos_test"]
        console.print(f"DNSMOS ovr/sig/bak: ref {mr['ovr']:.2f}/{mr['sig']:.2f}/{mr['bak']:.2f}  "
                      f"test [bold]{mt['ovr']:.2f}/{mt['sig']:.2f}/{mt['bak']:.2f}[/bold]")
    t = Table(title="octave-band delta (test − ref, dB, speech-active frames)")
    t.add_column("band (Hz)", justify="right")
    t.add_column("Δ dB", justify="right")
    for f0, d in res["bands"].items():
        t.add_row(str(f0), f"{d:+.1f}")
    console.print(t)
