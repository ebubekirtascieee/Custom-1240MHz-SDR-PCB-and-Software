import sys
import serial
import threading
import numpy as np
import pyqtgraph as pg
from pyqtgraph.Qt import QtCore, QtWidgets

# ==========================================
# GLOBAL VARIABLES (Cross-Thread Data)
# ==========================================


shared_fft_data = np.zeros(1024, dtype=np.uint16)
shared_freq = 1000000
shared_mod_type = 0
shared_bw = 0
data_lock = threading.Lock()


# ==========================================
# 1. THE DATA MINER (Background USB Thread)
# ==========================================
def serial_thread():
    global shared_fft_data, shared_freq, shared_mod_type, shared_bw

    # --- CHANGE 'COM6' TO YOUR ACTUAL TANG PRIMER PORT ---
    PORT = 'COM6'
    BAUD = 921600

    try:
        ser = serial.Serial(PORT, BAUD, timeout=1)
        print(f"Connected to FPGA on {PORT}!")
    except Exception as e:
        print(f"Failed to open port: {e}")
        return

    while True:
        try:
            # Hunt for the Sync Header: 0xAA 0x55
            if ser.read(1) == b'\xAA':
                if ser.read(1) == b'\x55':

                    # 5 bytes header + (1024 bins * 2 bytes) = 2053 total bytes
                    payload = ser.read(2053)

                    if len(payload) == 2053:
                        flags = payload[0]
                        mod_type = flags & 0x01
                        bw_extended = (flags >> 1) & 0x01

                        center_freq = (payload[1] << 24) | (payload[2] << 16) | \
                                      (payload[3] << 8) | payload[4]

                        # Unpack as Big-Endian 16-bit integers (>u2)
                        fft_bins = np.frombuffer(payload[5:], dtype=np.dtype('>u2'))

                        with data_lock:
                            np.copyto(shared_fft_data, fft_bins)
                            shared_freq = center_freq
                            shared_mod_type = mod_type
                            shared_bw = bw_extended

        except Exception as e:
            print(f"Serial Error: {e}")
            break


# ==========================================
# 2. THE PAINTER (GUI Thread)
# ==========================================

class SDRWindow(QtWidgets.QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Tang Primer 20K SDR - Professional Spectrum Analyzer")
        self.resize(1100, 700)

        main_widget = QtWidgets.QWidget()
        self.setCentralWidget(main_widget)
        layout = QtWidgets.QVBoxLayout(main_widget)

        self.info_label = QtWidgets.QLabel("Connecting to FPGA...")
        self.info_label.setStyleSheet(
            "font-family: 'Consolas', monospace; font-size: 22px; "
            "font-weight: bold; color: #00FF00; background-color: #111; "
            "padding: 15px; border: 2px solid #333; border-radius: 5px;"
        )
        layout.addWidget(self.info_label)

        self.plot_widget = pg.PlotWidget()
        self.plot_widget.setBackground('k')
        self.plot_widget.showGrid(x=True, y=True, alpha=0.4)

        # UPGRADE: Set Y-axis to -100 dBFS for 16-bit dynamic range
        self.plot_widget.setYRange(-100, 5, padding=0)
        self.plot_widget.setLabel('left', 'Amplitude', units='dBFS')
        self.plot_widget.setLabel('bottom', 'Frequency', units='MHz')
        layout.addWidget(self.plot_widget)

        self.curve = self.plot_widget.plot(pen=pg.mkPen('y', width=2))

        # --- Tuned Frequency Marker ---
        tune_pen = pg.mkPen(color=(255, 50, 50, 180), width=3)
        self.tune_line = pg.InfiniteLine(angle=90, movable=False, pen=tune_pen)
        self.plot_widget.addItem(self.tune_line)

        # --- Video Filter (EMA) Variables ---
        # Initialize at new noise floor (-100 dB)
        self.smooth_fft = np.full(512, -100.0)
        self.alpha = 0.3

        self.timer = QtCore.QTimer()
        self.timer.timeout.connect(self.update_gui)
        self.timer.start(33)

    def update_gui(self):
        with data_lock:
            local_fft = np.copy(shared_fft_data)
            local_freq = shared_freq
            local_mod = shared_mod_type
            local_bw = shared_bw

        raw_bins = local_fft[:512].astype(float)

        # se 65535.0 as the 16-bit full-scale reference
        raw_bins[raw_bins < 1] = 1
        dbfs_raw = 20 * np.log10(raw_bins / 65535.0)

        # VIDEO FILTER
        self.smooth_fft = (dbfs_raw * self.alpha) + (self.smooth_fft * (1.0 - self.alpha))

        # RF MAPPING
        LO_MHZ = 1242.0
        freq_x_axis = np.linspace(LO_MHZ, LO_MHZ + 10.125, 512)

        # Draw the curve
        self.curve.setData(freq_x_axis, self.smooth_fft)

        # Zoom Logic
        if local_bw == 1:
            self.plot_widget.setXRange(LO_MHZ, LO_MHZ + 5.0, padding=0)
        else:
            self.plot_widget.setXRange(LO_MHZ, LO_MHZ + 1.0, padding=0)

        # Update text
        mode_str = "FM" if local_mod == 1 else "AM"
        bw_str = "5 MHz" if local_bw == 1 else "1 MHz"
        tuned_freq = LO_MHZ + (local_freq / 1e6)

        self.info_label.setText(
            f"TUNED RF: {tuned_freq:.3f} MHz | MODE: {mode_str} | BW: {bw_str}"
        )

        # Snap red marker to frequency
        self.tune_line.setValue(tuned_freq)


# ==========================================
# EXECUTION ENTRY POINT
# ==========================================
if __name__ == '__main__':
    t = threading.Thread(target=serial_thread, daemon=True)
    t.start()

    app = QtWidgets.QApplication(sys.argv)
    window = SDRWindow()
    window.show()
    sys.exit(app.exec())