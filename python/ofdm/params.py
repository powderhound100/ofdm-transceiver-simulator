"""OFDM system parameters for simulation."""
from __future__ import annotations
from dataclasses import dataclass, field
import numpy as np


@dataclass
class OfdmParams:
    """OFDM system parameters.

    Default: small demonstration configuration suitable for the 802.11n
    rate-1/2 N=648 mock code (324 QPSK symbols -> ~7 OFDM symbols).
    """
    fft_size: int = 64
    cp_length: int = 16               # 25% overhead
    num_data_carriers: int = 48        # data subcarriers per OFDM symbol
    num_pilot_carriers: int = 4        # pilot subcarriers per OFDM symbol
    pilot_spacing: int = 12           # pilot every 12th subcarrier
    modulation: str = "QPSK"          # QPSK, 16QAM, 64QAM, 256QAM
    sample_rate: float = 6e6          # 6 MHz (ATSC 3.0 channel BW)

    @property
    def bits_per_symbol(self) -> int:
        return {"QPSK": 2, "16QAM": 4, "64QAM": 6, "256QAM": 8, "512QAM": 9, "1024QAM": 10, "2048QAM": 11}[self.modulation]

    @property
    def subcarrier_spacing(self) -> float:
        return self.sample_rate / self.fft_size

    def pilot_indices(self) -> np.ndarray:
        """Indices of pilot subcarriers within the used subcarriers."""
        total_used = self.num_data_carriers + self.num_pilot_carriers
        start = (self.fft_size - total_used) // 2
        indices = []
        for i in range(start, start + total_used, self.pilot_spacing):
            if i < start + total_used:
                indices.append(i)
        return np.array(indices[:self.num_pilot_carriers])

    def data_indices(self) -> np.ndarray:
        """Indices of data subcarriers within the FFT."""
        total_used = self.num_data_carriers + self.num_pilot_carriers
        start = (self.fft_size - total_used) // 2
        pilots = set(self.pilot_indices().tolist())
        return np.array([i for i in range(start, start + total_used) if i not in pilots])

    def symbols_per_codeword(self, code_n: int) -> int:
        """Number of OFDM symbols needed for one LDPC codeword."""
        qam_symbols = code_n // self.bits_per_symbol
        return int(np.ceil(qam_symbols / self.num_data_carriers))


DEFAULT_PARAMS = OfdmParams()
