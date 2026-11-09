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
    onLog('\n[Inject] Menyiapkan injeksi otomatis identity.json ke perangkat...\n');
    await new Promise(r => setTimeout(r, 1200));

    const encoder = new TextEncoder();
    const command = `SET_IDENTITY:${identityJson.trim()}\n`;
    const data = encoder.encode(command);

    try {
      if (typeof (this.transport as any).write === 'function') {
        await (this.transport as any).write(data);
      } else {
        const rawPort = (this.transport as any).device;
        if (rawPort?.writable) {
          const writer = rawPort.writable.getWriter();
          await writer.write(data);
          writer.releaseLock();
        }
      }
      onLog('[Inject] Payload identitas terkirim via USB Serial.\n');
    } catch (e: any) {
      onLog(`[Inject Error]: ${e?.message || e}\n`);
      return false;
    }

    // Read responses for up to 3.5 seconds to capture firmware confirmation
    let isClosed = false;
    const timeout = setTimeout(() => { isClosed = true; }, 3500);
    try {
      const decoder = new TextDecoder();
      await (this.transport as any).rawRead(
        (chunk: Uint8Array) => {
          const text = decoder.decode(chunk);
          onLog(text);
        },
        () => isClosed
      );
    } catch {} finally {
      clearTimeout(timeout);
    }

    return true;
  }

  async sendSerialText(text: string, onLog: (text: string) => void): Promise<void> {
    if (!this.transport) {
      throw new Error('Port serial belum terhubung.');
    }
    const encoder = new TextEncoder();
    const data = encoder.encode(text + '\n');
    const rawPort = (this.transport as any).device;
    if (rawPort && rawPort.writable) {
      const writer = rawPort.writable.getWriter();
      await writer.write(data);
      writer.releaseLock();
      onLog(`[Serial TX]: ${text}\n`);
    } else {
      throw new Error('Port tidak writable.');
    }
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

