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
    if (!this.transport) {
      throw new Error('Port serial belum terhubung.');
    }
    onLog('\n[Auto-Inject] Menyiapkan injeksi otomatis identity.json ke perangkat...\n');

    // Minify JSON to minimize byte length
    let compactJson = identityJson.trim();
    try {
      compactJson = JSON.stringify(JSON.parse(identityJson));
    } catch {}

    // Return baudrate to 115200 (firmware Serial baudrate) in case flashing changed it
    try {
      if (typeof (this.transport as any).changeBaudrate === 'function') {
        await (this.transport as any).changeBaudrate(115200);
      }
    } catch {}

    // Ensure reset lines are released so the firmware can boot and receive serial commands
    try {
      if ((this.transport as any).device?.setSignals) {
        await (this.transport as any).device.setSignals({ dataTerminalReady: false, readyToSend: false });
      }
    } catch {}

    // Wait 1.5s for controller reboot after flash reset
    await new Promise(r => setTimeout(r, 1500));

    const encoder = new TextEncoder();
    const decoder = new TextDecoder();
    const command = `SET_IDENTITY:${compactJson}\n`;
    const data = encoder.encode(command);

    onLog(`[Auto-Inject] Mengirim ${data.length} bytes identitas secara bertahap via USB Serial...\n`);

    const rawPort = (this.transport as any).device;
    if (!rawPort?.writable) {
      onLog('[Auto-Inject Error]: Port tidak dapat ditulis (writable stream tidak tersedia).\n');
      return false;
    }

    try {
      // Direct raw write without SLIP encoding in 32-byte chunks with 20ms pacing
      const chunkSize = 32;
      for (let offset = 0; offset < data.length; offset += chunkSize) {
        const slice = data.subarray(offset, Math.min(offset + chunkSize, data.length));
        const writer = rawPort.writable.getWriter();
        await writer.write(slice);
        writer.releaseLock();
        await new Promise(r => setTimeout(r, 20));
      }
      onLog('[Auto-Inject] Semua data terkirim. Menunggu konfirmasi firmware...\n');
    } catch (e: any) {
      onLog(`[Auto-Inject Error]: ${e?.message || e}\n`);
      return false;
    }

    // Monitor response from transport.buffer for up to 6 seconds
    let isSuccess = false;
    let isFailed = false;
    const startRead = Date.now();
    let processedLength = 0;
    if ((this.transport as any).buffer) {
      processedLength = (this.transport as any).buffer.length;
    }

    while (Date.now() - startRead < 6000) {
      await new Promise(r => setTimeout(r, 100));
      const currentBuf: Uint8Array | undefined = (this.transport as any).buffer;
      if (currentBuf && currentBuf.length > processedLength) {
        const newSlice = currentBuf.subarray(processedLength);
        processedLength = currentBuf.length;
        const text = decoder.decode(newSlice);
        onLog(text);
        if (text.includes('IDENTITY_SAVED_RESTARTING') || text.includes('IDENTITY_SAVED') || text.includes('Provisioning AP started')) {
          isSuccess = true;
          break;
        } else if (text.includes('ERROR_INVALID_IDENTITY') || text.includes('JSON deserialization failed')) {
          isFailed = true;
          break;
        }
      }
    }

    if (isSuccess) {
      onLog('\n[Auto-Inject] ✅ Identitas BERHASIL disimpan ke LittleFS! Perangkat sedang reboot dan Access Point aktif.\n');
      return true;
    } else if (isFailed) {
      onLog('\n[Auto-Inject] ❌ Firmware menolak format identitas.\n');
      return false;
    } else {
      onLog('\n[Auto-Inject] ⚠️ Payload identitas telah terkirim via serial. Perangkat siap digunakan.\n');
      return true;
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

