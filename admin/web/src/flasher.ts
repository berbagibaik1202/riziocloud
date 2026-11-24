import { ESPLoader, Transport } from 'esptool-js';

export interface ConnectedDeviceInfo {
  chip: string;
  flashSize?: string;
}

export class WebFlasher {
  private transport: Transport | null = null;
  private esploader: ESPLoader | null = null;
  private isConnected = false;
  private serialReader: ReadableStreamDefaultReader<Uint8Array> | null = null;
  private rawPort: any = null;

  isSupported(): boolean {
    return 'serial' in navigator;
  }

  getConnected(): boolean {
    return this.isConnected;
  }

  async connect(baudrate = 115200, onLog: (text: string) => void): Promise<ConnectedDeviceInfo> {
    if (!this.isSupported()) {
      throw new Error('Web Serial API tidak didukung pada browser ini. Gunakan Google Chrome atau Microsoft Edge di PC/Laptop.');
    }

    if (this.transport) {
      await this.disconnect();
    }

    onLog('Membuka dialog pemilihan port USB serial...\n');
    const port = await (navigator as any).serial.requestPort({ filters: [] });
    this.rawPort = port;

    this.transport = new Transport(port, true);

    const terminal = {
      clean: () => {},
      writeLine: (data: string) => onLog(data + '\n'),
      write: (data: string) => onLog(data),
    };

    onLog('Menghubungkan dan sinkronisasi bootloader ESP...\n');
    this.esploader = new ESPLoader({
      transport: this.transport,
      baudrate,
      terminal,
      debugLogging: false,
    });

    const chip = await this.esploader.main();
    onLog(`\nBerhasil terhubung ke chip: ${chip}\n`);

    let flashSize: string | undefined;
    try {
      flashSize = await this.esploader.detectFlashSize();
      if (flashSize) onLog(`Ukuran flash terdeteksi: ${flashSize}\n`);
    } catch {}

    this.isConnected = true;
    return { chip, flashSize };
  }

  async flash(
    files: Array<{ data: Uint8Array; address: number }>,
    onProgress: (percent: number, message: string) => void,
    onLog: (text: string) => void
  ): Promise<void> {
    if (!this.esploader || !this.isConnected) {
      throw new Error('ESP belum terhubung melalui USB.');
    }

    onLog('\nMemulai proses flashing ke flash memory...\n');
    await this.esploader.writeFlash({
      fileArray: files,
      flashMode: 'keep',
      flashFreq: 'keep',
      flashSize: 'keep',
      eraseAll: false,
      compress: true,
      reportProgress: (fileIndex: number, written: number, total: number) => {
        const pct = Math.min(100, Math.round((written / total) * 100));
        onProgress(pct, `Menulis partisi [${fileIndex + 1}/${files.length}]: ${pct}% (${written} / ${total} bytes)`);
      },
    });

    onLog('\nProses penulisan flash berhasil! Mereset chip untuk menjalankan firmware...\n');
    try {
      await this.esploader.after('hard_reset');
    } catch {
      onLog('Reset otomatis selesai.\n');
    }
  }

  async injectIdentity(identityJson: string, onLog: (text: string) => void): Promise<boolean> {
    onLog('\n[Auto-Inject] Menyiapkan port USB Serial untuk injeksi identitas langsung...\n');

    // If esptool transport is currently connected, cleanly disconnect it to release bootloader mode
    if (this.transport) {
      try {
        await this.disconnect();
      } catch {}
      await new Promise(r => setTimeout(r, 400));
    }

    // If port hasn't been selected yet, request user to pick port
    if (!this.rawPort) {
      if (!this.isSupported()) {
        throw new Error('Web Serial API tidak didukung pada browser ini.');
      }
      onLog('Pilih port USB serial perangkat Anda...\n');
      this.rawPort = await (navigator as any).serial.requestPort({ filters: [] });
    }

    // Ensure port is closed so we can open it cleanly at firmware baudrate (115200)
    try {
      if (this.rawPort.readable || this.rawPort.writable) {
        await this.rawPort.close();
      }
    } catch {}

    onLog('[Auto-Inject] Membuka port USB pada 115200 baud...\n');
    try {
      await this.rawPort.open({ baudRate: 115200 });
    } catch (e: any) {
      if (!e?.message?.includes('already open')) {
        onLog(`[Auto-Inject Error]: Gagal membuka port serial: ${e?.message || e}\n`);
        return false;
      }
    }

    // Hardware reset: toggle RTS to reboot into user application mode (boot mode 3,6)
    onLog('[Auto-Inject] Mereset controller ke mode eksekusi normal...\n');
    try {
      await this.rawPort.setSignals({ dataTerminalReady: false, requestToSend: true });
      await new Promise(r => setTimeout(r, 120));
      await this.rawPort.setSignals({ dataTerminalReady: false, requestToSend: false });
    } catch {}

    // Compact JSON
    let compactJson = identityJson.trim();
    try {
      compactJson = JSON.stringify(JSON.parse(identityJson));
    } catch {}

    const payload = `SET_IDENTITY:${compactJson}\n`;
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();

    let isSuccess = false;
    let isFailed = false;
    let failureReason = '';
    let stopReading = false;

    // Start background reader loop
    const readerPromise = (async () => {
      try {
        while (!stopReading && this.rawPort?.readable) {
          const reader = this.rawPort.readable.getReader();
          try {
            while (!stopReading) {
              const { value, done } = await reader.read();
              if (done || stopReading) break;
              if (value && value.length > 0) {
                const text = decoder.decode(value);
                onLog(text);
                if (text.includes('IDENTITY_SAVED') || text.includes('Provisioning AP started')) {
                  isSuccess = true;
                  stopReading = true;
                  break;
                }
                if (text.includes('ERROR_INVALID_IDENTITY') || text.includes('Missing required fields') || text.includes('JSON deserialization failed')) {
                  isFailed = true;
                  failureReason = text;
                  stopReading = true;
                  break;
                }
              }
            }
          } finally {
            reader.releaseLock();
          }
        }
      } catch {}
    })();

    // Wait 1.2s for controller to finish boot and reach loop()
    await new Promise(r => setTimeout(r, 1200));

    onLog(`[Auto-Inject] Mengirim payload SET_IDENTITY (${payload.length} bytes via 115200 baud)...\n`);
    try {
      if (this.rawPort?.writable) {
        const writer = this.rawPort.writable.getWriter();
        const data = encoder.encode(payload);
        const chunkSize = 32;
        for (let offset = 0; offset < data.length; offset += chunkSize) {
          const slice = data.subarray(offset, Math.min(offset + chunkSize, data.length));
          await writer.write(slice);
          await new Promise(r => setTimeout(r, 15));
        }
        writer.releaseLock();
        onLog('[Auto-Inject] Semua bytes identitas terkirim. Menunggu konfirmasi firmware...\n');
      }
    } catch (e: any) {
      onLog(`[Auto-Inject Error]: Gagal mengirim data serial: ${e?.message || e}\n`);
      stopReading = true;
      try { await this.rawPort?.close(); } catch {}
      return false;
    }

    // Wait up to 6 seconds for response
    const deadline = Date.now() + 6000;
    while (Date.now() < deadline && !isSuccess && !isFailed) {
      await new Promise(r => setTimeout(r, 100));
    }

    stopReading = true;
    try {
      if (this.rawPort?.readable?.locked) {
        await this.rawPort.readable.cancel();
      }
    } catch {}

    await new Promise(r => setTimeout(r, 200));

    try {
      await this.rawPort?.close();
    } catch {}

    if (isSuccess) {
      onLog('\n[Auto-Inject] ✅ Identitas BERHASIL disimpan ke LittleFS! Perangkat me-reboot dan Access Point aktif.\n');
      return true;
    } else if (isFailed) {
      onLog(`\n[Auto-Inject] ❌ Firmware menolak format identitas: ${failureReason}\n`);
      return false;
    } else {
      onLog('\n[Auto-Inject] ❌ Gagal mendapatkan konfirmasi dari firmware (timeout).\n');
      return false;
    }
  }

  async sendSerialText(text: string, onLog: (text: string) => void): Promise<void> {
    if (!this.transport) {
      throw new Error('Port serial belum terhubung.');
    }
    const encoder = new TextEncoder();
    const data = encoder.encode(text + '\n');
    const writeChunk = async (chunk: Uint8Array) => {
      const rawPort = (this.transport as any).device;
      if (rawPort?.writable) {
        const writer = rawPort.writable.getWriter();
        await writer.write(chunk);
        writer.releaseLock();
      } else if (typeof (this.transport as any).write === 'function') {
        await (this.transport as any).write(chunk);
      }
    };

    if (data.length > 64) {
      for (let offset = 0; offset < data.length; offset += 32) {
        const slice = data.subarray(offset, Math.min(offset + 32, data.length));
        await writeChunk(slice);
        await new Promise(r => setTimeout(r, 15));
      }
    } else {
      await writeChunk(data);
    }
    onLog(`[Serial TX]: ${text}\n`);
  }

  async disconnect(): Promise<void> {
    this.isConnected = false;
    if (this.serialReader) {
      try { await this.serialReader.cancel(); } catch {}
      this.serialReader = null;
    }
    if (this.transport) {
      try { await this.transport.disconnect(); } catch {}
      this.transport = null;
    }
    this.esploader = null;
  }
}

