import './style.css';
import QRCode from 'qrcode';
import { WebFlasher, type ConnectedDeviceInfo } from './flasher.js';

type Row = Record<string, any>;

interface CurrentUser {
  id: string;
  email: string;
  name: string;
  role: 'superadmin' | 'tenant_admin' | 'user' | 'admin';
  tenant_id?: string | null;
  status: string;
}

const ISRG_ROOT_X1_CA = `-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4
WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu
ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY
MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc
h77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+
0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U
A5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW
T8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH
B5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC
B5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv
KBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn
OlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn
jh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw
qHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI
rU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV
HRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq
hkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL
ubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ
3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK
NFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5
ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur
TkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC
jNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc
oyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq
4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA
mRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d
emyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=
-----END CERTIFICATE-----`;

const app = document.querySelector<HTMLDivElement>('#app')!;
let access = '';
let refresh = '';
let page = 'Dashboard';
let busy = false;
let currentUser: CurrentUser | null = null;
let view: 'landing' | 'dashboard' = 'landing';
let showLoginModal = false;

// Flasher State
const flasher = new WebFlasher();
let selectedFlasherSn = '';
let flasherLogText = 'Log terminal siap. Silakan sambungkan port USB ESP.\n';
let flasherProgress = 0;
let flasherProgressMsg = '';
let connectedChipInfo: ConnectedDeviceInfo | null = null;
let loadedIdentity: Row | null = null;

const sessionIdentities = new Map<string, Row>();
let base = localStorage.getItem('rizio_api') || '/v1';
let refreshWork: Promise<void> | undefined;

const esc = (v: unknown) => String(v ?? '—').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));

async function api(path: string, method = 'GET', body?: unknown, retry = true): Promise<any> {
  const response = await fetch(base + path, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(access ? { Authorization: `Bearer ${access}` } : {})
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  });

  if (response.status === 401 && refresh && retry) {
    refreshWork ??= api('/auth/refresh', 'POST', { refresh_token: refresh }, false)
      .then(d => {
        access = d.access_token;
        refresh = d.refresh_token;
        currentUser = d.user;
      })
      .finally(() => { refreshWork = undefined; });
    try {
      await refreshWork;
    } catch (e) {
      access = '';
      refresh = '';
      currentUser = null;
      view = 'landing';
      renderView();
      throw e;
    }
    return api(path, method, body, false);
  }

  const result = await response.json();
  if (!response.ok || result.status === 'error') throw new Error(result.message || 'Permintaan gagal');
  return result.data;
}

async function restoreSession() {
  refresh = sessionStorage.getItem('rizio_refresh') || '';
  if (!refresh) {
    view = 'landing';
    renderView();
    return;
  }
  try {
    const d = await api('/auth/refresh', 'POST', { refresh_token: refresh }, false);
    access = d.access_token;
    refresh = d.refresh_token;
    currentUser = d.user;
    sessionStorage.setItem('rizio_refresh', refresh);
    view = 'dashboard';
    renderView();
  } catch {
    access = '';
    refresh = '';
    currentUser = null;
    sessionStorage.removeItem('rizio_refresh');
    view = 'landing';
    renderView();
  }
}

function notice(message: string, error = false) {
  const target = document.querySelector('#notice');
  if (target) {
    target.className = `notice ${error ? 'error' : ''}`;
    target.textContent = message;
  }
}

function data(form: HTMLFormElement): Row {
  return Object.fromEntries(new FormData(form).entries());
}

function downloadFile(filename: string, value: string) {
  const link = document.createElement('a');
  link.href = URL.createObjectURL(new Blob([value], { type: 'text/plain;charset=utf-8' }));
  link.download = filename;
  link.click();
  URL.revokeObjectURL(link.href);
}

async function showClaimQr(sn: string) {
  const value = `ESPCTRL://device?sn=${encodeURIComponent(sn)}`;
  const image = await QRCode.toDataURL(value, { width: 280, margin: 2 });
  const dialog = document.createElement('dialog');
  dialog.innerHTML = `<h2>QR perangkat · ${esc(sn)}</h2><img src="${image}" alt="QR perangkat ${esc(sn)}" style="width:280px;height:280px;display:block;margin:16px auto"><p>${esc(value)}</p><div class="dialog-actions"><button onclick="window.print()">Print</button> <button class="secondary" id="close-qr">Tutup</button></div>`;
  document.body.append(dialog);
  dialog.querySelector<HTMLButtonElement>('#close-qr')!.onclick = () => dialog.remove();
  dialog.showModal();
}

function rows(value: any): Row[] {
  return Array.isArray(value) ? value : value?.items || value?.devices || value?.users || value?.firmwares || value?.commands || value?.logs || value?.tenants || [];
}

function table(items: Row[], columns: string[], action?: (r: Row) => string): string {
  const deviceColumns = columns.includes('owner_user_id') && columns.includes('firmware_version')
    ? ['sn', 'name', 'device_type', 'relay_type', 'model', 'channels', 'firmware_version', 'tenant_id', 'owner_user_id', 'online', 'disabled', 'last_seen']
    : columns;
  return items.length
    ? `<div class="table"><table><thead><tr>${deviceColumns.map(c => `<th>${esc(c.replaceAll('_', ' '))}</th>`).join('')}${action ? '<th>Tindakan</th>' : ''}</tr></thead><tbody>${items.map(r => `<tr>${deviceColumns.map(c => `<td>${esc(typeof r[c] === 'object' ? JSON.stringify(r[c]) : r[c])}</td>`).join('')}${action ? `<td>${action(r)}</td>` : ''}</tr>`).join('')}</tbody></table></div>`
    : '<p class="muted">Belum ada data tersedia.</p>';
}

async function act(work: () => Promise<void>) {
  if (busy) return;
  busy = true;
  document.querySelectorAll<HTMLButtonElement>('main button').forEach(b => b.disabled = true);
  try {
    await work();
  } catch (e) {
    notice(String(e), true);
  } finally {
    busy = false;
    document.querySelectorAll<HTMLButtonElement>('main button').forEach(b => b.disabled = false);
  }
}

function appendFlasherLog(msg: string) {
  flasherLogText += msg;
  const terminal = document.querySelector<HTMLDivElement>('#flasher-terminal-box');
  if (terminal) {
    terminal.textContent = flasherLogText;
    terminal.scrollTop = terminal.scrollHeight;
  }
}

// =========================================================================
// RENDER ROUTER
// =========================================================================
function renderView() {
  if (view === 'landing') {
    renderLandingPage();
  } else {
    renderDashboard();
  }
}

// =========================================================================
// 1. LANDING PAGE
// =========================================================================
function renderLandingPage() {
  app.innerHTML = `
    <div class="landing-wrapper">
      <!-- Navbar -->
      <header class="landing-nav">
        <a href="#" class="brand-logo">
          RizIO<span class="brand-dot">.</span>
          <span class="brand-tag">Cloud & Edge IoT</span>
        </a>
        <nav class="landing-nav-links">
          <a href="#keunggulan">Keunggulan</a>
          <a href="#fitur">Fitur Utama</a>
          <a href="#solusi">Solusi Bisnis</a>
          <a href="#harga">Paket SaaS</a>
        </nav>
        <div class="nav-actions">
          ${currentUser ? `
            <button id="open-portal-btn">Dashboard (${esc(currentUser.name)})</button>
            <button id="nav-logout-btn" class="secondary">Keluar</button>
          ` : `
            <button id="open-login-btn">Masuk Portal</button>
          `}
        </div>
      </header>

      <!-- Hero Section -->
      <section class="hero-section">
        <div class="hero-badge">
          ✨ RizIO IoT Platform • Web Flasher & SaaS Multi-Tenant Ready
        </div>
        <h1 class="hero-title">
          Kendali Cerdas & Monitoring IoT <span>Tanpa Batas Jaringan</span>
        </h1>
        <p class="hero-subtitle">
          Platform IoT modular berbasis ESP8266 & ESP32. Menyediakan kontrol multi-channel relay real-time, telemetri sensor DHT11, otomatisasi terjadwal, flash firmware langsung via browser, dan fallback jaringan lokal (LAN) instan saat offline.
        </p>
        <div class="hero-ctas">
          <button id="hero-portal-btn">
            ${currentUser ? 'Lanjut ke Dashboard' : 'Masuk Portal Administrator / Tenant'} →
          </button>
          <a href="#keunggulan"><button class="secondary">Pelajari Keunggulan</button></a>
        </div>

        <!-- Interactive Live Simulation Mockup -->
        <div class="hero-mockup-wrapper">
          <div class="mockup-header">
            <span class="mockup-dot red"></span>
            <span class="mockup-dot yellow"></span>
            <span class="mockup-dot green"></span>
            <span class="mockup-title">RizIO Live Controller Preview • ESP32 Smart Unit</span>
          </div>
          <div class="mockup-body">
            <div class="mock-device-card">
              <div class="mock-header">
                <div>
                  <strong style="font-size:15px;color:var(--dark)">Unit Smart Office 4CH</strong>
                  <div class="muted" style="font-size:12px">SN: ESP-DEMO-001 • IP: 192.168.1.45</div>
                </div>
                <span class="mock-status-pill">ONLINE • MQTT TLS</span>
              </div>
              <div class="mock-channels-grid">
                <div class="mock-channel-btn active" data-mock-id="1">
                  <span>CH 1: Lampu Utama</span>
                  <div class="mock-toggle"></div>
                </div>
                <div class="mock-channel-btn active" data-mock-id="2">
                  <span>CH 2: Lampu Luar</span>
                  <div class="mock-toggle"></div>
                </div>
                <div class="mock-channel-btn" data-mock-id="3">
                  <span>CH 3: Pompa Sirkulasi</span>
                  <div class="mock-toggle"></div>
                </div>
                <div class="mock-channel-btn" data-mock-id="4">
                  <span>CH 4: Exhaust Fan</span>
                  <div class="mock-toggle"></div>
                </div>
              </div>
            </div>

            <div class="mock-telemetry-box">
              <div>
                <span class="muted" style="font-weight:600;font-size:12px;text-transform:uppercase">Telemetri Lingkungan (DHT11)</span>
                <div class="telemetry-val" id="mock-temp">28.4°C</div>
                <div class="telemetry-meta">
                  <span>Kelembapan: <strong id="mock-hum">62%</strong></span>
                  <span>RSSI: <strong>-58 dBm</strong></span>
                </div>
              </div>
              <div style="font-size:12px;color:var(--primary);background:var(--accent-light);padding:8px 12px;border-radius:8px">
                ⏱ Respon LAN Offline: <strong>&lt; 18 ms</strong> • Cloud QoS 1
              </div>
            </div>
          </div>
        </div>
      </section>

      <!-- Metrics Bar -->
      <div class="metrics-banner">
        <div class="metric-box">
          <strong>&lt; 200 ms</strong>
          <span>Latensi Kendali LAN</span>
        </div>
        <div class="metric-box">
          <strong>100%</strong>
          <span>Otonom Saat Offline</span>
        </div>
        <div class="metric-box">
          <strong>Web Serial</strong>
          <span>Flash ESP via Browser</span>
        </div>
        <div class="metric-box">
          <strong>SaaS Ready</strong>
          <span>Isolasi Multi-Tenant Penuh</span>
        </div>
      </div>

      <!-- 3 Core USPs -->
      <section id="keunggulan" class="section-wrapper">
        <div class="section-header">
          <h2>Mengapa Bisnis Memilih RizIO?</h2>
          <p>Dirancang untuk memecahkan kelemahan terbesar sistem smart controller konvensional di pasar komersial dan industri.</p>
        </div>
        <div class="usp-grid">
          <div class="usp-card">
            <div class="usp-icon">⚡</div>
            <h3>Dual Connectivity (Cloud + LAN)</h3>
            <p>Perangkat tetap dapat dikontrol secara instan di jaringan lokal meskipun koneksi internet ISP terputus, tanpa ketergantungan server luar.</p>
          </div>
          <div class="usp-card">
            <div class="usp-icon">🏢</div>
            <h3>SaaS & Multi-Tenancy B2B</h3>
            <p>Kelola ratusan cabang, klien, atau entitas organisasi terpisah dalam satu cluster backend. Setiap tenant memiliki admin, user, dan perangkatnya sendiri.</p>
          </div>
          <div class="usp-card">
            <div class="usp-icon">🔌</div>
            <h3>Web Serial Flasher Terintegrasi</h3>
            <p>Tenant Admin dapat memprogram dan me-reset firmware serta file identity.json langsung dari browser tanpa perlu menginstall Python atau PlatformIO.</p>
          </div>
        </div>
      </section>

      <!-- Features Grid -->
      <section id="fitur" class="section-wrapper">
        <div class="section-header">
          <h2>Fitur Terlengkap dari Edge ke Cloud</h2>
          <p>Mendukung kebutuhan kendali listrik, monitoring iklim mikro, serta deployment skala besar.</p>
        </div>
        <div class="grid">
          <div class="card">
            <h3>🎛️ Relay Multi-Channel (1–8 Channel)</h3>
            <p>Kendalikan relay dengan mode active-low/high yang dapat dikonfigurasi per channel. Beri nama alias fleksibel seperti <em>"Lampu Luar"</em> atau <em>"Pompa Utama"</em>.</p>
          </div>
          <div class="card">
            <h3>🌡️ Sensor DHT11 & Histori Suhu</h3>
            <p>Pencatatan telemetri berkala otomatis. Backend menyimpan dan mengagregasi histori suhu serta kelembapan (interval 30–60 menit) siap divisualisasikan.</p>
          </div>
          <div class="card">
            <h3>⏰ Scenes & Smart Schedules</h3>
            <p>Jadwalkan eksekusi multi-channel berdasarkan hari dan jam lokal. Mendukung sinkronisasi offline ke firmware perangkat secara otomatis.</p>
          </div>
          <div class="card">
            <h3>🚀 Remote Firmware OTA & Web Flasher</h3>
            <p>Distribusikan pembaruan firmware ke seluruh armada perangkat via cloud OTA atau flash kabel USB via Web Serial browser.</p>
          </div>
        </div>
      </section>

      <!-- Solutions by Sector -->
      <section id="solusi" class="section-wrapper">
        <div class="section-header">
          <h2>Solusi untuk Berbagai Sektor Industri</h2>
          <p>RizIO telah diaplikasikan pada ragam skenario operasional modern.</p>
        </div>
        <div class="solutions-grid">
          <div class="solution-card">
            <div class="solution-icon">🏢</div>
            <div class="solution-content">
              <h3>Smart Building & Perkantoran</h3>
              <p>Efisiensi penggunaan energi listrik gedung, penjadwalan otomatis lampu dan AC kantor, serta pemantauan suhu server room.</p>
              <div class="solution-tags"><span>Hemat Energi</span><span>Audit Log</span><span>Multi-Lantai</span></div>
            </div>
          </div>
          <div class="solution-card">
            <div class="solution-icon">🌾</div>
            <div class="solution-content">
              <h3>Smart Agriculture & Greenhouse</h3>
              <p>Otomatisasi penyiraman nutrisi tanaman dan pemantauan iklim mikro (suhu & kelembapan) untuk hasil panen optimal.</p>
              <div class="solution-tags"><span>DHT11 Telemetri</span><span>Irigasi Otomatis</span><span>Schedules</span></div>
            </div>
          </div>
        </div>
      </section>

      <!-- SaaS Pricing Plans -->
      <section id="harga" class="section-wrapper">
        <div class="section-header">
          <h2>Pilihan Paket Layanan SaaS</h2>
          <p>Fleksibilitas biaya sesuai dengan skala pertumbuhan armada perangkat Anda.</p>
        </div>
        <div class="pricing-grid">
          <div class="pricing-card">
            <div class="pricing-header">
              <h3>Starter</h3>
              <p class="muted">Cocok untuk proof-of-concept atau instalasi skala kecil.</p>
              <div class="pricing-price">Rp 199k <span>/ bulan</span></div>
            </div>
            <ul class="pricing-features">
              <li>Maksimal 10 Perangkat ESP</li>
              <li>1 Akun Tenant Admin</li>
              <li>Kontrol Cloud & Local LAN</li>
              <li>Web Serial Flasher Tool</li>
              <li>Standard Community Support</li>
            </ul>
            <button class="outline login-trigger-btn">Pilih Starter</button>
          </div>

          <div class="pricing-card featured">
            <span class="popular-badge">Paling Populer</span>
            <div class="pricing-header">
              <h3>Business Pro</h3>
              <p class="muted">Solusi ideal untuk perkantoran, greenhouse, dan multi-cabang.</p>
              <div class="pricing-price">Rp 699k <span>/ bulan</span></div>
            </div>
            <ul class="pricing-features">
              <li>Maksimal 50 Perangkat ESP</li>
              <li>Multi-User / Operator Berkelompok</li>
              <li>Histori Sensor Lengkap 30 Hari</li>
              <li>Web Flasher & OTA Deployment</li>
              <li>Scenes & Smart Schedules Penuh</li>
              <li>Prioritas Dukungan Teknis</li>
            </ul>
            <button class="login-trigger-btn">Mulai Business Pro</button>
          </div>

          <div class="pricing-card">
            <div class="pricing-header">
              <h3>Enterprise</h3>
              <p class="muted">Dedicated server, custom firmware, dan integrasi API khusus.</p>
              <div class="pricing-price">Custom <span>/ tahun</span></div>
            </div>
            <ul class="pricing-features">
              <li>Tanpa Batas Kuota Perangkat</li>
              <li>Multi-Tenant Sub-Organizations</li>
              <li>Private Cluster MQTT TLS Dedicated</li>
              <li>Custom Branding & Whitelabel App</li>
              <li>Dedicated SLA & Support Engineer</li>
            </ul>
            <button class="outline login-trigger-btn">Hubungi Sales</button>
          </div>
        </div>
      </section>

      <!-- CTA Banner -->
      <div class="cta-banner">
        <h2>Mulai Bangun Solusi IoT yang Tangguh Hari Ini</h2>
        <p>Bergabunglah dengan ekosistem RizIO untuk kontrol perangkat pintar yang andal, aman, dan siap skala industri.</p>
        <button id="cta-login-btn" style="background:#299d89;font-size:16px;padding:14px 32px">
          ${currentUser ? 'Buka Dashboard Sekarang' : 'Masuk ke Portal Administrator'}
        </button>
      </div>

      <!-- Footer -->
      <footer>
        <div class="footer-inner">
          <div>
            <div class="footer-logo">RizIO<span style="color:#299d89">.</span></div>
            <p style="color:#627e84;margin-top:6px;font-size:13px">Sistem Kontrol & Monitoring IoT Multi-Tenant Berbasis Cloud dan Edge.</p>
          </div>
          <div class="footer-links">
            <a href="#keunggulan">Keunggulan</a>
            <a href="#fitur">Fitur</a>
            <a href="#solusi">Solusi</a>
            <a href="#harga">Harga</a>
          </div>
        </div>
        <div class="footer-copy">
          © 2026 RizIO ESP Cloud Controller. Seluruh hak cipta dilindungi.
        </div>
      </footer>
    </div>

    <!-- Login Modal -->
    ${showLoginModal ? renderLoginModal() : ''}
  `;

  attachLandingEvents();
}

function renderLoginModal(): string {
  return `
    <div class="modal-login" id="modal-login-overlay">
      <div class="modal-login-card">
        <button class="modal-close-btn" id="close-login-modal">✕</button>
        <h2 style="font-size:24px;margin-bottom:6px">Masuk ke Portal</h2>
        <p class="muted" style="margin-bottom:20px">Gunakan akun Superadmin atau Tenant Admin Anda.</p>
        <form id="portal-login-form">
          <label>Alamat API Backend
            <input name="base" value="${esc(base)}" required>
          </label>
          <label>Email
            <input name="email" type="email" autocomplete="username" placeholder="admin@example.com" required>
          </label>
          <label>Kata Sandi
            <input name="password" type="password" autocomplete="current-password" placeholder="••••••••••••" required>
          </label>
          <button type="submit" id="portal-submit-btn" style="margin-top:8px">Masuk</button>
        </form>
        <div id="notice" role="status"></div>
      </div>
    </div>
  `;
}

function attachLandingEvents() {
  document.querySelector('#open-login-btn')?.addEventListener('click', () => {
    showLoginModal = true;
    renderLandingPage();
  });
  document.querySelector('#hero-portal-btn')?.addEventListener('click', () => {
    if (currentUser) {
      view = 'dashboard';
      renderView();
    } else {
      showLoginModal = true;
      renderLandingPage();
    }
  });
  document.querySelector('#open-portal-btn')?.addEventListener('click', () => {
    view = 'dashboard';
    renderView();
  });
  document.querySelector('#cta-login-btn')?.addEventListener('click', () => {
    if (currentUser) {
      view = 'dashboard';
      renderView();
    } else {
      showLoginModal = true;
      renderLandingPage();
    }
  });
  document.querySelectorAll('.login-trigger-btn').forEach(b => {
    b.addEventListener('click', () => {
      showLoginModal = true;
      renderLandingPage();
    });
  });

  document.querySelector('#nav-logout-btn')?.addEventListener('click', async () => {
    try { await api('/auth/logout', 'POST', { refresh_token: refresh }); } catch {}
    access = '';
    refresh = '';
    currentUser = null;
    sessionStorage.removeItem('rizio_refresh');
    renderLandingPage();
  });

  document.querySelectorAll<HTMLDivElement>('.mock-channel-btn').forEach(btn => {
    btn.onclick = () => {
      btn.classList.toggle('active');
      const temp = document.querySelector('#mock-temp');
      if (temp) {
        const current = parseFloat(temp.textContent || '28.4');
        temp.textContent = `${(current + (btn.classList.contains('active') ? 0.2 : -0.2)).toFixed(1)}°C`;
      }
    };
  });

  const overlay = document.querySelector('#modal-login-overlay');
  if (overlay) {
    document.querySelector('#close-login-modal')?.addEventListener('click', () => {
      showLoginModal = false;
      renderLandingPage();
    });
    overlay.addEventListener('click', (e) => {
      if (e.target === overlay) {
        showLoginModal = false;
        renderLandingPage();
      }
    });

    const form = document.querySelector<HTMLFormElement>('#portal-login-form');
    if (form) {
      form.onsubmit = async (e) => {
        e.preventDefault();
        const f = e.currentTarget as HTMLFormElement;
        const d = data(f);
        base = String(d.base).replace(/\/$/, '');
        if (!base.startsWith('/') && !base.startsWith('https://') && !/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?\/v1$/.test(base)) {
          notice('Gunakan URL HTTPS atau /v1.', true);
          return;
        }
        localStorage.setItem('rizio_api', base);
        const btn = form.querySelector('button')!;
        btn.disabled = true;
        try {
          const r = await api('/auth/login', 'POST', { email: d.email, password: d.password });
          access = r.access_token;
          refresh = r.refresh_token;
          currentUser = r.user;
          sessionStorage.setItem('rizio_refresh', refresh);
          showLoginModal = false;
          view = 'dashboard';
          renderView();
        } catch (err) {
          notice(String(err), true);
          btn.disabled = false;
        }
      };
    }
  }
}

// =========================================================================
// 2. DASHBOARD VIEW (SUPER ADMIN & TENANT ADMIN)
// =========================================================================
function getAccessiblePages(): string[] {
  if (currentUser?.role === 'tenant_admin') {
    return ['Dashboard', 'Perangkat', 'Flash Web', 'Pengguna', 'Perintah', 'Log'];
  }
  // Superadmin / Admin
  return ['Dashboard', 'Tenant', 'Pengguna', 'Perangkat', 'Flash Web', 'Online', 'Offline', 'Firmware', 'OTA', 'Perintah', 'Log', 'Sistem'];
}

async function renderDashboard() {
  const pages = getAccessiblePages();
  if (!pages.includes(page)) page = 'Dashboard';

  const isTenantAdmin = currentUser?.role === 'tenant_admin';

  app.innerHTML = `
    <div class="shell">
      <aside>
        <h2>
          RizIO<span style="color:#299d89">.</span>
        </h2>
        <span class="tenant-badge">
          ${isTenantAdmin ? `TENANT ADMIN` : `SUPERADMIN`}
        </span>
        <nav>
          ${pages.map(p => `<button data-page="${p}" class="${p === page ? 'active' : ''}">${p}</button>`).join('')}
        </nav>
        <div style="margin-top:auto;padding-top:20px;border-top:1px solid rgba(255,255,255,0.08)">
          <div style="font-size:12px;color:#8faab0;margin-bottom:8px">Masuk sebagai:<br><strong style="color:white">${esc(currentUser?.name)}</strong></div>
          <button id="view-landing-btn" class="secondary" style="width:100%;font-size:12px;padding:8px">← Halaman Depan</button>
        </div>
      </aside>
      <main>
        <header>
          <div>
            <div class="muted">${isTenantAdmin ? 'PORTAL TENANT / ' + esc(currentUser?.tenant_id) : 'ADMINISTRATOR / RIZIO CLOUD'}</div>
            <h1>${page}</h1>
          </div>
          <div class="toolbar">
            ${isTenantAdmin && page === 'Perangkat' ? '<button id="claim-device-btn">+ Klaim Perangkat</button>' : ''}
            ${!isTenantAdmin && page === 'Perangkat' ? '<button id="add-device">+ Tambah perangkat</button>' : ''}
            <button id="reload" class="secondary">Perbarui</button>
            <button id="logout" class="secondary">Keluar</button>
          </div>
        </header>
        <div id="notice" role="status"></div>
        <section id="content" aria-live="polite"><p>Memuat data…</p></section>
      </main>
    </div>
  `;

  document.querySelectorAll<HTMLButtonElement>('[data-page]').forEach(b => {
    b.onclick = () => { page = b.dataset.page!; void renderDashboard(); };
  });
  document.querySelector<HTMLButtonElement>('#reload')!.onclick = () => void renderDashboard();
  document.querySelector<HTMLButtonElement>('#view-landing-btn')?.addEventListener('click', () => {
    view = 'landing';
    renderView();
  });
  document.querySelector<HTMLButtonElement>('#add-device')?.addEventListener('click', () => {
    const modal = document.querySelector<HTMLDialogElement>('#device-inventory');
    if (!modal) return;
    modal.showModal();
    (modal.querySelector('[name="sn"]') as HTMLInputElement | undefined)?.focus();
  });
  document.querySelector<HTMLButtonElement>('#claim-device-btn')?.addEventListener('click', () => {
    const snPrompt = prompt('Masukkan Serial Number (SN) perangkat untuk diklaim ke Tenant Anda:');
    if (!snPrompt || !snPrompt.trim()) return;
    void act(async () => {
      await api('/tenant/devices/claim', 'POST', { sn: snPrompt.trim() });
      await renderDashboard();
      notice(`Perangkat ${snPrompt} berhasil diklaim ke tenant Anda.`);
    });
  });

  document.querySelector<HTMLButtonElement>('#logout')!.onclick = async () => {
    try { await api('/auth/logout', 'POST', { refresh_token: refresh }); } catch {}
    access = '';
    refresh = '';
    currentUser = null;
    sessionStorage.removeItem('rizio_refresh');
    view = 'landing';
    renderView();
  };

  const currentPage = page;
  const content = document.querySelector('#content')!;

  try {
    // -------------------------------------------------------------
    // Page: Dashboard
    // -------------------------------------------------------------
    if (page === 'Dashboard') {
      if (isTenantAdmin) {
        const [tenantInfo, devices] = await Promise.all([
          api('/tenant/info'),
          api('/tenant/devices')
        ]);
        const devList = rows(devices);
        const onlineCount = devList.filter(d => d.online).length;
        content.innerHTML = `
          <div class="stats">
            <div class="card stat"><span class="muted">Nama Organisasi / Tenant</span><strong>${esc(tenantInfo.name)}</strong></div>
            <div class="card stat"><span class="muted">Total Perangkat Tenant</span><strong>${devList.length} / ${esc(tenantInfo.max_devices)}</strong></div>
            <div class="card stat"><span class="muted">Perangkat Online</span><strong>${onlineCount}</strong></div>
            <div class="card stat"><span class="muted">Total Anggota Tenant</span><strong>${esc(tenantInfo.total_users)}</strong></div>
          </div>
          <div class="card">
            <h2>Status & Konfigurasi Tenant</h2>
            <p>Slug: <code>${esc(tenantInfo.slug)}</code> • Status: <span class="pill ${tenantInfo.status === 'active' ? 'active' : 'suspended'}">${esc(tenantInfo.status)}</span></p>
          </div>
        `;
      } else {
        const s = await api('/admin/summary');
        content.innerHTML = `
          <div class="stats">
            ${Object.entries(s).filter(([, v]) => typeof v !== 'object').map(([k, v]) => `
              <div class="card stat">
                <span class="muted">${esc(k.replaceAll('_', ' '))}</span>
                <strong>${esc(v)}</strong>
              </div>
            `).join('')}
          </div>
          <div class="card">
            <h2>Distribusi firmware & koneksi</h2>
            <pre>${esc(JSON.stringify(s, null, 2))}</pre>
          </div>
        `;
      }
    }
    // -------------------------------------------------------------
    // Page: Tenant (Super Admin Only)
    // -------------------------------------------------------------
    else if (page === 'Tenant' && !isTenantAdmin) {
      const tenants = rows(await api('/admin/tenants'));
      content.innerHTML = `
        <div class="card">
          <h2>Daftarkan Tenant Baru</h2>
          <form id="create-tenant-form" class="grid">
            <label>Nama Organisasi / Tenant<input name="name" placeholder="PT Maju Makmur" required></label>
            <label>Slug Unik<input name="slug" placeholder="maju-makmur" pattern="[a-z0-9-]+" required></label>
            <label>Batas Kuota Perangkat (max_devices)<input name="max_devices" type="number" min="1" max="1000" value="50" required></label>
            <label>Email Admin Tenant<input name="admin_email" type="email" placeholder="admin@majumakmur.com" required></label>
            <label>Nama Admin Tenant<input name="admin_name" placeholder="Budi Santoso" required></label>
            <label>Password Admin Tenant (min 12 kar)<input name="admin_password" type="password" minlength="12" required></label>
            <button type="submit" style="grid-column:1/-1">Daftarkan Tenant</button>
          </form>
        </div>
        <div class="card">
          <h2>Daftar Seluruh Tenant</h2>
          ${table(tenants, ['name', 'slug', 'status', 'max_devices', 'total_devices', 'online_devices', 'total_users', 'created_at'], r => `
            <button data-toggle-tenant="${esc(r.id)}" data-status="${r.status === 'active' ? 'suspended' : 'active'}" class="secondary">
              ${r.status === 'active' ? 'Suspend' : 'Aktifkan'}
            </button>
            <button data-edit-quota="${esc(r.id)}" data-quota="${r.max_devices}" class="secondary">Ubah Kuota</button>
          `)}
        </div>
      `;

      document.querySelector<HTMLFormElement>('#create-tenant-form')!.onsubmit = (e) => {
        e.preventDefault();
        const values = data(e.currentTarget as HTMLFormElement);
        void act(async () => {
          await api('/admin/tenants', 'POST', {
            name: values.name,
            slug: values.slug,
            max_devices: Number(values.max_devices),
            admin_email: values.admin_email,
            admin_name: values.admin_name,
            admin_password: values.admin_password
          });
          await renderDashboard();
          notice('Tenant baru berhasil didaftarkan.');
        });
      };

      document.querySelectorAll<HTMLButtonElement>('[data-toggle-tenant]').forEach(btn => {
        btn.onclick = () => void act(async () => {
          const id = btn.dataset.toggleTenant!;
          const targetStatus = btn.dataset.status!;
          await api(`/admin/tenants/${encodeURIComponent(id)}`, 'PATCH', { status: targetStatus });
          await renderDashboard();
          notice(`Status tenant diperbarui menjadi ${targetStatus}.`);
        });
      });

      document.querySelectorAll<HTMLButtonElement>('[data-edit-quota]').forEach(btn => {
        btn.onclick = () => void act(async () => {
          const id = btn.dataset.editQuota!;
          const oldQuota = btn.dataset.quota!;
          const newQuota = prompt('Masukkan kuota perangkat baru (max_devices):', oldQuota);
          if (!newQuota || isNaN(Number(newQuota)) || Number(newQuota) < 1) return;
          await api(`/admin/tenants/${encodeURIComponent(id)}`, 'PATCH', { max_devices: Number(newQuota) });
          await renderDashboard();
          notice('Kuota tenant berhasil diperbarui.');
        });
      });
    }
    // -------------------------------------------------------------
    // Page: Flash Web (ESP Web Flasher & Identity Writer)
    // -------------------------------------------------------------
    else if (page === 'Flash Web') {
      const devices = rows(isTenantAdmin ? await api('/tenant/devices') : await api('/admin/devices'));
      const firmwares = rows(await api('/admin/firmwares').catch(() => []));
      const isSerialSupported = flasher.isSupported();

      content.innerHTML = `
        <div class="card">
          <h2>Web Serial ESP Flasher & Injeksi Identitas Otomatis</h2>
          <p class="muted">
            Program firmware dan konfigurasikan identitas perangkat (<code>identity.json</code>) ke board ESP8266 / ESP32 Anda secara otomatis melalui kabel USB browser (Google Chrome atau Microsoft Edge). Tidak memerlukan instalasi Python, PlatformIO, atau pembuatan file partisi biner manual.
          </p>
          <div style="margin:12px 0">
            ${isSerialSupported
              ? '<span class="flasher-status-pill connected">✓ Browser mendukung Web Serial API</span>'
              : '<span class="flasher-status-pill disconnected">⚠️ Browser Anda belum mendukung Web Serial. Gunakan Google Chrome atau Edge desktop.</span>'}
            <span class="flasher-status-pill ${flasher.getConnected() ? 'connected' : 'disconnected'}" id="flasher-connection-pill">
              ${flasher.getConnected()
                ? `🔌 Terhubung: ${esc(connectedChipInfo?.chip || 'ESP')} ${connectedChipInfo?.flashSize ? '(' + esc(connectedChipInfo.flashSize) + ')' : ''}`
                : '🔌 USB: Belum Terhubung'}
            </span>
          </div>
        </div>

        <!-- Step 1: Pilih Perangkat & Identitas -->
        <div class="card">
          <div class="flasher-step">
            <div class="flasher-step-num">1</div>
            <div class="flasher-step-content">
              <h3>Pilih Perangkat Target</h3>
              <p class="muted">Pilih perangkat dari tenant Anda. Data <code>identity.json</code> akan dimuat dan disuntikkan secara otomatis via serial setelah proses flash selesai.</p>
              <label>Pilih Perangkat
                <select id="flasher-device-select">
                  <option value="">-- Pilih Perangkat --</option>
                  ${devices.map(d => `<option value="${esc(d.sn)}" ${d.sn === selectedFlasherSn ? 'selected' : ''}>${esc(d.name || d.sn)} (${esc(d.sn)} • ${esc(d.model)})</option>`).join('')}
                </select>
              </label>

              <div id="flasher-identity-details" style="margin-top:16px;display:${loadedIdentity ? 'block' : 'none'}">
                <div class="dialog-actions" style="margin-bottom:12px">
                  <button type="button" id="download-identity-btn" class="secondary">📥 Unduh Backup identity.json</button>
                  <button type="button" id="download-ca-btn" class="secondary">📥 Unduh Backup ca.pem</button>
                </div>
                <label>Pratinjau Kredensial Identitas yang Akan Diinjeksi
                  <pre id="identity-json-preview" style="max-height:160px;overflow-y:auto">${loadedIdentity ? esc(JSON.stringify(loadedIdentity, null, 2)) : ''}</pre>
                </label>
              </div>
            </div>
          </div>
        </div>

        <!-- Step 2: Konfigurasi Firmware -->
        <div class="card">
          <div class="flasher-step">
            <div class="flasher-step-num">2</div>
            <div class="flasher-step-content">
              <h3>Pilih Sumber Firmware Binary (.bin)</h3>
              <div style="display:grid;gap:12px;margin:12px 0">
                <label style="display:flex;align-items:center;gap:8px;font-weight:normal;cursor:pointer">
                  <input type="radio" name="fw-source" value="server" checked>
                  <strong>Gunakan Firmware Resmi dari Server</strong>
                </label>
                <div id="server-fw-container" style="margin-left:24px">
                  <label>Pilih Versi Firmware
                    <select id="flasher-server-fw">
                      ${firmwares.map(f => `<option value="${esc(f.url)}">[${f.firmware_type === 'factory' ? 'FACTORY/USB' : 'OTA'}] ${esc(f.model)} v${esc(f.version)} (${esc(f.hardware_version)})</option>`).join('')}
                      ${firmwares.length === 0 ? '<option value="">(Belum ada katalog firmware di server)</option>' : ''}
                    </select>
                  </label>
                  <p class="muted" style="margin-top:6px;font-size:12px">Alamat flash offset default: <code>0x00000</code> (ESP8266) atau <code>0x10000</code> (ESP32).</p>
                </div>

                <label style="display:flex;align-items:center;gap:8px;font-weight:normal;cursor:pointer">
                  <input type="radio" name="fw-source" value="custom">
                  <strong>Upload File Firmware Sendiri (.bin)</strong>
                </label>
                <div id="custom-fw-container" style="margin-left:24px;display:none">
                  <input type="file" id="flasher-custom-file" accept=".bin">
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- Step 3: Hubungkan Port USB Serial & Flashing -->
        <div class="card">
          <div class="flasher-step">
            <div class="flasher-step-num">3</div>
            <div class="flasher-step-content">
              <h3>Koneksi USB & Flash Otomatis</h3>
              <div class="grid" style="align-items:end;margin-bottom:16px">
                <label>Baud Rate Flashing
                  <select id="flasher-baudrate">
                    <option value="115200" selected>115200 (Rekomendasi / Paling Stabil)</option>
                    <option value="460800">460800 (Cepat)</option>
                    <option value="921600">921600 (Sangat Cepat)</option>
                  </select>
                </label>
                <div class="toolbar" style="margin:0">
                  <button type="button" id="flasher-connect-btn" ${!isSerialSupported ? 'disabled' : ''}>
                    🔌 Hubungkan ke ESP
                  </button>
                  <button type="button" id="flasher-disconnect-btn" class="secondary" style="display:none">
                    Putuskan USB
                  </button>
                </div>
              </div>

              <div style="margin:16px 0">
                <button type="button" id="flasher-start-btn" style="background:#299d89;padding:12px 24px;font-size:15px;font-weight:bold">
                  🚀 Flash & Injeksi Identitas Otomatis (1-Klik)
                </button>
              </div>

              <div id="flasher-progress-wrapper" style="display:${flasherProgress > 0 ? 'block' : 'none'}">
                <div class="progress-container">
                  <div class="progress-bar" id="flasher-progress-bar" style="width:${flasherProgress}%"></div>
                </div>
                <div id="flasher-progress-label" style="font-size:13px;font-weight:600;color:var(--primary)">${esc(flasherProgressMsg)}</div>
              </div>
            </div>
          </div>
        </div>

        <!-- Step 4: Terminal Log Console -->
        <div class="card">
          <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:10px">
            <h3>Terminal Monitor & Log Serial</h3>
            <button type="button" id="flasher-clear-log" class="secondary" style="font-size:12px;padding:4px 10px">Bersihkan Log</button>
          </div>
          <div class="flasher-terminal" id="flasher-terminal-box">${esc(flasherLogText)}</div>
        </div>
      `;

      attachFlasherEvents(devices);
    }
    // -------------------------------------------------------------
    // Page: Pengguna (Super Admin or Tenant Admin)
    // -------------------------------------------------------------
    else if (page === 'Pengguna') {
      if (isTenantAdmin) {
        const users = rows(await api('/tenant/users'));
        content.innerHTML = `
          <div class="card">
            <h2>Tambah Anggota Tenant</h2>
            <form id="tenant-user-form" class="grid">
              <label>Nama Lengkap<input name="name" required></label>
              <label>Email<input name="email" type="email" required></label>
              <label>Password (min 12 kar)<input name="password" type="password" minlength="12" required></label>
              <label>Peran (Role)
                <select name="role">
                  <option value="user">Operator / User</option>
                  <option value="tenant_admin">Tenant Admin Tambahan</option>
                </select>
              </label>
              <button type="submit" style="grid-column:1/-1">Tambah Anggota</button>
            </form>
          </div>
          <div class="card">
            <h2>Daftar Anggota Tenant</h2>
            ${table(users, ['name', 'email', 'role', 'status', 'created_at'], r => `
              <button data-tenant-user-status="${esc(r.id)}" data-value="${r.status !== 'active'}" class="secondary">
                ${r.status === 'active' ? 'Nonaktifkan' : 'Aktifkan'}
              </button>
              <button data-tenant-user-delete="${esc(r.id)}" class="danger">Hapus</button>
            `)}
          </div>
        `;

        document.querySelector<HTMLFormElement>('#tenant-user-form')!.onsubmit = (e) => {
          e.preventDefault();
          const values = data(e.currentTarget as HTMLFormElement);
          void act(async () => {
            await api('/tenant/users', 'POST', {
              name: values.name,
              email: values.email,
              password: values.password,
              role: values.role
            });
            await renderDashboard();
            notice('Anggota tenant berhasil ditambahkan.');
          });
        };

        document.querySelectorAll<HTMLButtonElement>('[data-tenant-user-status]').forEach(btn => {
          btn.onclick = () => void act(async () => {
            await api(`/tenant/users/${encodeURIComponent(btn.dataset.tenantUserStatus!)}`, 'PATCH', {
              status: btn.dataset.value === 'true' ? 'active' : 'disabled'
            });
            await renderDashboard();
          });
        });

        document.querySelectorAll<HTMLButtonElement>('[data-tenant-user-delete]').forEach(btn => {
          btn.onclick = () => void act(async () => {
            if (!confirm('Hapus pengguna ini dari tenant?')) return;
            await api(`/tenant/users/${encodeURIComponent(btn.dataset.tenantUserDelete!)}`, 'DELETE');
            await renderDashboard();
          });
        });
      } else {
        const users = rows(await api('/admin/users'));
        content.innerHTML = `
          <div class="card">
            <h2>Tambah Pengguna Global</h2>
            <form id="user-form" class="grid">
              <label>Nama<input name="name" required></label>
              <label>Email<input name="email" type="email" required></label>
              <label>Password<input name="password" type="password" minlength="12" required></label>
              <button>Tambah pengguna</button>
            </form>
          </div>
          <div class="card">
            <h2>Daftar Pengguna Global</h2>
            ${table(users, ['name', 'email', 'role', 'tenant_id', 'status', 'claimed_devices', 'created_at'], r => `
              <button data-user-status="${esc(r.id)}" data-value="${r.status !== 'active'}" class="secondary">
                ${r.status === 'active' ? 'Nonaktifkan' : 'Aktifkan'}
              </button>
            `)}
          </div>
        `;
        document.querySelector<HTMLFormElement>('#user-form')!.onsubmit = (e) => {
          e.preventDefault();
          const values = data(e.currentTarget as HTMLFormElement);
          void act(async () => {
            await api('/admin/users', 'POST', { name: values.name, email: values.email, password: values.password });
            await renderDashboard();
          });
        };
        document.querySelectorAll<HTMLButtonElement>('[data-user-status]').forEach(b => {
          b.onclick = () => void act(async () => {
            await api('/admin/users/' + encodeURIComponent(b.dataset.userStatus!), 'PATCH', { status: b.dataset.value === 'true' ? 'active' : 'disabled' });
            await renderDashboard();
          });
        });
      }
    }
    // -------------------------------------------------------------
    // Page: Perangkat (Super Admin or Tenant Admin)
    // -------------------------------------------------------------
    else if (['Perangkat', 'Online', 'Offline'].includes(page)) {
      let devices = rows(isTenantAdmin ? await api('/tenant/devices') : await api('/admin/devices'));
      if (page === 'Online') devices = devices.filter(d => d.online);
      if (page === 'Offline') devices = devices.filter(d => !d.online);

      content.innerHTML = `
        <div class="card">
          <h2>${isTenantAdmin ? 'Perangkat Tenant Anda' : 'Inventaris Perangkat Global'}</h2>
          ${table(devices, ['sn', 'name', 'model', 'firmware_version', ...(isTenantAdmin ? [] : ['tenant_id']), 'owner_user_id', 'online', 'disabled', 'last_seen'], r => `
            <button data-flash="${esc(r.sn)}" data-name="${esc(r.name || '')}" data-model="${esc(r.model || '')}" style="background:#299d89">⚡ Flash</button>
            <button data-qr="${esc(r.sn)}" class="secondary">QR</button>
            <button data-info="${esc(r.sn)}" class="secondary">Telemetri</button>
            ${!isTenantAdmin ? `<button data-identity="${esc(r.sn)}" class="secondary">identity.json</button>` : ''}
            <button data-edit="${esc(r.sn)}" class="secondary">Edit Nama</button>
            ${!isTenantAdmin ? `<button data-assign-tenant="${esc(r.sn)}" class="secondary">Set Tenant</button>` : ''}
            <button data-disable="${esc(r.sn)}" data-value="${!r.disabled}">${r.disabled ? 'Aktifkan' : 'Nonaktifkan'}</button>
            ${!isTenantAdmin ? `<button data-hard-delete="${esc(r.sn)}" class="danger">Hapus</button>` : ''}
          `)}
        </div>
      `;

      document.querySelectorAll<HTMLButtonElement>('[data-flash]').forEach(b => {
        b.onclick = () => {
          void openFlasherModal(b.dataset.flash!, b.dataset.name, b.dataset.model);
        };
      });

      document.querySelectorAll<HTMLButtonElement>('[data-qr]').forEach(b => b.onclick = () => showClaimQr(b.dataset.qr!));
      document.querySelectorAll<HTMLButtonElement>('[data-identity]').forEach(b => {
        b.onclick = () => {
          const identity = sessionIdentities.get(b.dataset.identity!);
          const dialog = document.createElement('dialog');
          dialog.innerHTML = identity
            ? `<h2>identity.json · ${esc(b.dataset.identity)}</h2><pre>${esc(JSON.stringify(identity, null, 2))}</pre><div class="dialog-actions"><button id="download">Download</button> <button class="secondary" id="close-identity">Tutup</button></div>`
            : `<h2>identity.json tidak tersedia</h2><p>Device key hanya ditampilkan saat inventory dibuat dan tidak dapat diambil ulang dari backend.</p><div class="dialog-actions"><button class="secondary" id="close-identity">Tutup</button></div>`;
          document.body.append(dialog);
          if (identity) dialog.querySelector<HTMLButtonElement>('#download')!.onclick = () => downloadFile('identity.json', JSON.stringify(identity, null, 2) + '\n');
          dialog.querySelector<HTMLButtonElement>('#close-identity')!.onclick = () => dialog.remove();
          dialog.showModal();
        };
      });

      document.querySelectorAll<HTMLButtonElement>('[data-edit]').forEach(b => {
        b.onclick = () => act(async () => {
          const device = devices.find(d => d.sn === b.dataset.edit);
          const name = prompt('Nama perangkat baru:', device?.name || '');
          if (name && name.trim() && name.trim() !== device?.name) {
            await api(`/devices/${encodeURIComponent(b.dataset.edit!)}`, 'PATCH', { name: name.trim() });
            await renderDashboard();
          }
        });
      });

      document.querySelectorAll<HTMLButtonElement>('[data-assign-tenant]').forEach(b => {
        b.onclick = () => act(async () => {
          const sn = b.dataset.assignTenant!;
          const device = devices.find(d => d.sn === sn);
          const tenantId = prompt('Masukkan ID Tenant (UUID) untuk mengalokasikan perangkat ini (kosongkan untuk unassign):', device?.tenant_id || '');
          if (tenantId === null) return;
          const payload = { tenant_id: tenantId.trim() ? tenantId.trim() : null };
          await api(`/admin/devices/${encodeURIComponent(sn)}`, 'PATCH', payload);
          await renderDashboard();
          notice(`Alokasi tenant untuk ${sn} diperbarui.`);
        });
      });

      document.querySelectorAll<HTMLButtonElement>('[data-disable]').forEach(b => {
        b.onclick = () => act(async () => {
          if (!confirm(`${b.textContent} ${b.dataset.disable}?`)) return;
          await api('/admin/devices/' + encodeURIComponent(b.dataset.disable!), 'PATCH', { disabled: b.dataset.value === 'true' });
          await renderDashboard();
        });
      });

      document.querySelectorAll<HTMLButtonElement>('[data-hard-delete]').forEach(b => {
        b.onclick = () => act(async () => {
          const sn = b.dataset.hardDelete!;
          if (prompt(`Ketik SN ${sn} untuk menghapus permanen:`) !== sn) return;
          await api('/admin/devices/' + encodeURIComponent(sn), 'DELETE');
          await renderDashboard();
          notice(`Perangkat ${sn} berhasil dihapus permanen.`);
        });
      });

      document.querySelectorAll<HTMLButtonElement>('[data-info]').forEach(b => {
        b.onclick = () => {
          const device = devices.find(d => d.sn === b.dataset.info);
          const dialog = document.createElement('dialog');
          dialog.innerHTML = `<h2>Telemetri & Status ${esc(device?.sn)}</h2><pre>${esc(JSON.stringify(device, null, 2))}</pre><div class="dialog-actions"><button class="secondary" id="close-telemetry">Tutup</button></div>`;
          document.body.append(dialog);
          dialog.querySelector<HTMLButtonElement>('#close-telemetry')!.onclick = () => dialog.remove();
          dialog.showModal();
        };
      });
    }
    // -------------------------------------------------------------
    // Page: Firmware (Super Admin)
    // -------------------------------------------------------------
    else if (page === 'Firmware') {
      const firmwares = rows(await api('/admin/firmwares'));
      content.innerHTML = `
        <div class="card">
          <h2>Unggah Binary Firmware</h2>
          <p class="muted" style="margin-bottom:14px">
            Pilih file binary <code>.bin</code>. File otomatis disimpan di server dan URL unduhan HTTPS dibuat otomatis.
          </p>
          <form id="fw-upload-form" style="display:grid;gap:14px">
            <div class="grid">
              <label>Tipe Firmware
                <select name="firmware_type" required>
                  <option value="ota" selected>📡 OTA Update (Pembaruan Nirkabel Over-The-Air)</option>
                  <option value="factory">⚡ Factory / Flash USB (Flashing Awal via Web Serial)</option>
                </select>
              </label>
              <label>Model Perangkat
                <input name="model" placeholder="contoh: ESP8266 atau ESP32" required>
              </label>
              <label>Versi Hardware
                <input name="hardware_version" placeholder="contoh: 1.0" required>
              </label>
              <label>Versi Firmware (SemVer)
                <input name="version" placeholder="contoh: 1.1.0" required pattern="^\\d+\\.\\d+\\.\\d+(-[a-zA-Z0-9.-]+)?$">
              </label>
            </div>

            <div style="background:#f4f7f6;padding:12px;border-radius:6px;border:1px dashed #cbdad6">
              <label style="font-weight:600;margin-bottom:6px;display:block">Pilih File Binary (.bin)</label>
              <input type="file" id="binary-file" accept=".bin" required style="font-size:13px">
              <div id="file-calc-info" style="font-size:12px;color:#555;margin-top:6px">Ukuran file dan SHA256 akan dihitung otomatis saat file dipilih.</div>
            </div>

            <label>Catatan Rilis
              <textarea name="release_notes" rows="2" placeholder="Catatan perubahan atau changelog firmware..."></textarea>
            </label>

            <button type="submit" style="width:fit-content">🚀 Unggah Binary ke Server</button>
          </form>

          <details style="margin-top:20px;padding-top:14px;border-top:1px solid #e0eae6">
            <summary style="cursor:pointer;color:#555;font-size:13px">Opsi Lanjutan: Daftarkan URL Hosting Eksternal (S3/CDN)</summary>
            <p class="muted" style="font-size:12px;margin:8px 0">Gunakan form ini jika file binary di-hosting di CDN / bucket HTTPS eksternal Anda sendiri.</p>
            <form id="firmware-manual-form" style="display:grid;gap:10px;margin-top:8px">
              <div class="grid">
                <label>Tipe Firmware
                  <select name="firmware_type">
                    <option value="ota">OTA Update</option>
                    <option value="factory">Factory / Flash USB</option>
                  </select>
                </label>
                <label>Model<input name="model" required></label>
                <label>Hardware Version<input name="hardware_version" required></label>
                <label>Versi<input name="version" required></label>
                <label>URL Direct HTTPS<input name="url" type="url" placeholder="https://..." required></label>
                <label>SHA256 Checksum<input name="checksum" required></label>
                <label>Ukuran Byte<input name="file_size" type="number" min="1" required></label>
              </div>
              <label>Catatan Rilis<textarea name="release_notes"></textarea></label>
              <button type="submit" class="secondary" style="width:fit-content">Daftarkan Metadata Manual</button>
            </form>
          </details>
        </div>

        <div class="card">
          <h2>Katalog Firmware Server</h2>
          ${table(firmwares, ['model', 'hardware_version', 'version', 'firmware_type', 'file_size', 'is_active', 'created_at'])}
        </div>
      `;

      const binaryInput = document.querySelector<HTMLInputElement>('#binary-file')!;
      const fileCalcInfo = document.querySelector<HTMLDivElement>('#file-calc-info')!;

      binaryInput.onchange = async () => {
        const file = binaryInput.files?.[0];
        if (!file) return;
        fileCalcInfo.textContent = 'Menghitung SHA-256...';
        const hash = await crypto.subtle.digest('SHA-256', await file.arrayBuffer());
        const sha = Array.from(new Uint8Array(hash)).map(b => b.toString(16).padStart(2, '0')).join('');
        fileCalcInfo.textContent = `Ukuran: ${(file.size / 1024).toFixed(1)} KB (${file.size} bytes) • SHA256: ${sha}`;
      };

      document.querySelector<HTMLFormElement>('#fw-upload-form')!.onsubmit = e => {
        e.preventDefault();
        const form = e.currentTarget as HTMLFormElement;
        const binary = binaryInput.files?.[0];
        if (!binary) return notice('Pilih file binary terlebih dahulu.', true);
        const fData = data(form);

        act(async () => {
          const body = new FormData();
          body.set('file', binary);
          body.set('firmware_type', String(fData.firmware_type || 'ota'));
          body.set('model', String(fData.model || ''));
          body.set('hardware_version', String(fData.hardware_version || ''));
          body.set('version', String(fData.version || ''));
          body.set('release_notes', String(fData.release_notes || ''));

          const r = await fetch(base + '/admin/firmwares/upload', {
            method: 'POST',
            headers: { Authorization: 'Bearer ' + access },
            body
          });
          const result = await r.json();
          if (!r.ok) throw new Error(result.message || 'Upload gagal');
          await renderDashboard();
          notice(`Binary firmware [${fData.firmware_type}] ${fData.model} v${fData.version} berhasil disimpan.`);
        });
      };

      document.querySelector<HTMLFormElement>('#firmware-manual-form')!.onsubmit = e => {
        e.preventDefault();
        const d = data(e.currentTarget as HTMLFormElement);
        act(async () => {
          await api('/admin/firmwares', 'POST', { ...d, file_size: Number(d.file_size) });
          await renderDashboard();
          notice('Metadata firmware manual disimpan.');
        });
      };
    }
    // -------------------------------------------------------------
    // Page: OTA (Super Admin)
    // -------------------------------------------------------------
    else if (page === 'OTA') {
      const [ds, fs] = await Promise.all([
        api('/admin/devices'),
        api('/admin/firmwares?type=ota')
      ]);
      const otaList = rows(fs).filter(f => !f.firmware_type || f.firmware_type === 'ota');

      content.innerHTML = `
        <div class="card">
          <h2>Deployment Firmware OTA</h2>
          <p class="muted">Kirim pembaruan firmware secara nirkabel (Over-The-Air) ke perangkat aktif. Hanya firmware bertipe <strong>OTA</strong> yang tersedia di daftar.</p>
          <form id="ota" style="display:grid;gap:12px;max-width:600px">
            <label>Pilih Perangkat Target
              <select name="sn" required>
                ${rows(ds).map(d => `<option value="${esc(d.sn)}">${esc(d.name || d.sn)} · ${esc(d.model)} / ${esc(d.hardware_version)} (${d.online ? 'Online' : 'Offline'})</option>`).join('')}
                ${rows(ds).length === 0 ? '<option value="" disabled selected>(Belum ada perangkat terdaftar)</option>' : ''}
              </select>
            </label>
            <label>Pilih Firmware OTA
              <select name="firmware_id" required>
                ${otaList.map(f => `<option value="${esc(f.id)}">[OTA] ${esc(f.model)} / ${esc(f.hardware_version)} · v${esc(f.version)} (${(Number(f.file_size) / 1024).toFixed(0)} KB)</option>`).join('')}
                ${otaList.length === 0 ? '<option value="" disabled selected>(Belum ada firmware OTA terdaftar - silakan unggah firmware tipe OTA di menu Firmware)</option>' : ''}
              </select>
            </label>
            <button ${otaList.length === 0 ? 'disabled' : ''}>🚀 Kirim Perintah OTA</button>
          </form>
          <p class="muted" style="margin-top:14px;font-size:12px">Pantau respons status ACK pada menu <strong>Perintah</strong> dan versi firmware perangkat setelah reboot.</p>
        </div>
      `;
      document.querySelector<HTMLFormElement>('#ota')!.onsubmit = e => {
        e.preventDefault();
        const d = data(e.currentTarget as HTMLFormElement);
        if (!d.firmware_id) return notice('Pilih firmware OTA terlebih dahulu.', true);
        act(async () => {
          if (!confirm(`Kirim pembaruan firmware OTA ke perangkat ${d.sn}?`)) return;
          const r = await api('/admin/devices/' + encodeURIComponent(d.sn) + '/ota', 'POST', { firmware_id: d.firmware_id });
          notice(`OTA diantrikan. ID: ${r.request_id}. Menunggu konfirmasi perangkat.`);
        });
      };
    }
    // -------------------------------------------------------------
    // Page: Perintah
    // -------------------------------------------------------------
    else if (page === 'Perintah') {
      content.innerHTML = `<div class="card"><h2>Log Antrean Perintah</h2>${table(rows(await api('/admin/commands')), ['request_id', 'sn', 'command', 'command_status', 'error', 'created_at', 'ack_at'])}</div>`;
    }
    // -------------------------------------------------------------
    // Page: Log
    // -------------------------------------------------------------
    else if (page === 'Log') {
      content.innerHTML = `<div class="card"><h2>Audit & Telemetry Logs</h2>${table(rows(await api('/admin/logs')), ['sn', 'event_type', 'payload', 'created_at'])}</div>`;
    }
    // -------------------------------------------------------------
    // Page: Sistem (Super Admin)
    // -------------------------------------------------------------
    else {
      const r = await fetch(base.replace(/\/v1$/, '') + '/health');
      content.innerHTML = `<div class="card"><h2>Kesehatan Layanan</h2><pre>${esc(JSON.stringify(await r.json(), null, 2))}</pre></div>`;
    }
  } catch (e) {
    if (currentPage === page) {
      content.innerHTML = '<div class="card"><p>Data tidak dapat dimuat. Gunakan Perbarui untuk mencoba kembali.</p></div>';
      notice(String(e), true);
    }
  }
}

// Open Flasher Popup Modal directly from device list
async function openFlasherModal(sn: string, deviceName = '', deviceModel = '') {
  let modal = document.querySelector<HTMLDialogElement>('#flasher-modal');
  if (modal) modal.remove();

  modal = document.createElement('dialog');
  modal.id = 'flasher-modal';
  modal.className = 'card';
  document.body.append(modal);

  const firmwares = rows(await api('/admin/firmwares').catch(() => []));
  const isSerialSupported = flasher.isSupported();
  let modalIdentity: any = null;
  let modalLogText = `Log terminal siap untuk ${sn}. Silakan sambungkan USB ESP.\n`;

  modal.innerHTML = `
    <div style="display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:14px;border-bottom:1px solid #e0eae6;padding-bottom:12px">
      <div>
        <h2 style="margin:0 0 4px;font-size:20px;display:flex;align-items:center;gap:8px">
          ⚡ Web Serial Flasher & Injeksi Identitas
        </h2>
        <p class="muted" style="margin:0;font-size:13px">
          Perangkat: <strong>${esc(sn)}</strong> ${deviceName ? `(${esc(deviceName)})` : ''} • Model: <strong>${esc(deviceModel || 'ESP')}</strong>
        </p>
      </div>
      <button type="button" id="close-modal-flasher" class="secondary" style="padding:6px 12px;font-size:14px">✕ Tutup</button>
    </div>

    <div style="margin-bottom:14px">
      ${isSerialSupported
        ? '<span class="flasher-status-pill connected" style="font-size:11px">✓ Web Serial API Didukung</span>'
        : '<span class="flasher-status-pill disconnected" style="font-size:11px">⚠️ Gunakan Google Chrome atau Edge Desktop</span>'}
      <span class="flasher-status-pill ${flasher.getConnected() ? 'connected' : 'disconnected'}" id="modal-conn-pill" style="font-size:11px">
        ${flasher.getConnected()
          ? `🔌 Terhubung: ${esc(connectedChipInfo?.chip || 'ESP')} ${connectedChipInfo?.flashSize ? '(' + esc(connectedChipInfo.flashSize) + ')' : ''}`
          : '🔌 USB: Belum Terhubung'}
      </span>
    </div>

    <!-- Step 1: Kredensial Identitas Perangkat -->
    <div class="card" style="margin-bottom:12px;padding:14px;background:#f8fbf9">
      <div style="display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:8px">
        <div>
          <strong style="color:var(--primary);font-size:14px">1. Identitas Perangkat (identity.json)</strong>
          <div id="modal-id-status" style="font-size:12px;color:#555;margin-top:2px">Memuat identitas dari server...</div>
        </div>
        <div style="display:flex;gap:6px">
          <button type="button" id="modal-dl-id-btn" class="secondary" style="font-size:11px;padding:4px 8px" disabled>📥 Unduh identity.json</button>
          <button type="button" id="modal-dl-ca-btn" class="secondary" style="font-size:11px;padding:4px 8px">📥 Unduh ca.pem</button>
        </div>
      </div>
      <pre id="modal-id-preview" style="max-height:85px;overflow-y:auto;margin-top:8px;font-size:11px;background:#fff;padding:8px;border-radius:6px;border:1px solid #e0eae6"></pre>
    </div>

    <!-- Step 2: Pilih Firmware Binary -->
    <div class="card" style="margin-bottom:12px;padding:14px">
      <strong style="color:var(--primary);font-size:14px">2. Pilih Firmware Binary (.bin)</strong>
      <div style="display:grid;gap:8px;margin:10px 0">
        <label style="display:flex;align-items:center;gap:8px;cursor:pointer;font-weight:normal">
          <input type="radio" name="modal-fw-source" value="server" checked>
          <span>Gunakan Firmware Resmi Server</span>
        </label>
        <div id="modal-server-container" style="margin-left:24px">
          <select id="modal-server-fw" style="width:100%;font-size:13px">
            ${firmwares.map(f => `<option value="${esc(f.url)}" ${f.model === deviceModel ? 'selected' : ''}>[${f.firmware_type === 'factory' ? 'FACTORY/USB' : 'OTA'}] ${esc(f.model)} v${esc(f.version)} (${esc(f.hardware_version)})</option>`).join('')}
            ${firmwares.length === 0 ? '<option value="">(Belum ada katalog firmware di server)</option>' : ''}
          </select>
        </div>
        <label style="display:flex;align-items:center;gap:8px;cursor:pointer;font-weight:normal">
          <input type="radio" name="modal-fw-source" value="custom">
          <span>Upload File Firmware Sendiri (.bin)</span>
        </label>
        <div id="modal-custom-container" style="margin-left:24px;display:none">
          <input type="file" id="modal-custom-file" accept=".bin" style="font-size:12px">
        </div>
      </div>
    </div>

    <!-- Step 3: Sambungkan USB & Flash -->
    <div class="card" style="margin-bottom:12px;padding:14px">
      <strong style="color:var(--primary);font-size:14px">3. Sambungkan USB & Flash Otomatis</strong>
      <div style="display:flex;gap:10px;align-items:center;margin:10px 0;flex-wrap:wrap">
        <button type="button" id="modal-conn-btn" ${!isSerialSupported ? 'disabled' : ''}>
          🔌 Hubungkan USB
        </button>
        <button type="button" id="modal-disconn-btn" class="secondary" style="display:none">
          Putuskan USB
        </button>
        <button type="button" id="modal-flash-btn" style="background:#299d89;font-weight:bold;padding:10px 20px">
          🚀 Flash & Injeksi Identitas (1-Klik)
        </button>
      </div>

      <div id="modal-progress-wrap" style="display:none;margin-top:10px">
        <div class="progress-container">
          <div class="progress-bar" id="modal-progress-bar" style="width:0%"></div>
        </div>
        <div id="modal-progress-label" style="font-size:12px;font-weight:600;color:var(--primary);margin-top:4px">Menyiapkan...</div>
      </div>
    </div>

    <!-- Terminal Konsol -->
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:4px">
      <span style="font-size:12px;font-weight:600;color:#555">Terminal Log Serial ESP:</span>
      <button type="button" id="modal-clear-log-btn" class="secondary" style="font-size:11px;padding:2px 8px">Bersihkan Log</button>
    </div>
    <div id="modal-terminal-box" class="terminal-box" style="height:130px;overflow-y:auto;font-family:monospace;font-size:11px;background:#111;color:#33ff66;padding:10px;border-radius:6px;white-space:pre-wrap">Log terminal siap. Silakan sambungkan USB ESP.\n</div>
  `;

  modal.showModal();

  const terminalBox = modal.querySelector<HTMLDivElement>('#modal-terminal-box')!;
  const appendModalLog = (txt: string) => {
    modalLogText += txt;
    if (terminalBox) {
      terminalBox.textContent = modalLogText;
      terminalBox.scrollTop = terminalBox.scrollHeight;
    }
  };

  const idStatus = modal.querySelector<HTMLDivElement>('#modal-id-status')!;
  const idPreview = modal.querySelector<HTMLPreElement>('#modal-id-preview')!;
  const dlIdBtn = modal.querySelector<HTMLButtonElement>('#modal-dl-id-btn')!;
  const dlCaBtn = modal.querySelector<HTMLButtonElement>('#modal-dl-ca-btn')!;
  const connBtn = modal.querySelector<HTMLButtonElement>('#modal-conn-btn')!;
  const disconnBtn = modal.querySelector<HTMLButtonElement>('#modal-disconn-btn')!;
  const flashBtn = modal.querySelector<HTMLButtonElement>('#modal-flash-btn')!;
  const connPill = modal.querySelector<HTMLSpanElement>('#modal-conn-pill')!;
  const progressWrap = modal.querySelector<HTMLDivElement>('#modal-progress-wrap')!;
  const progressBar = modal.querySelector<HTMLDivElement>('#modal-progress-bar')!;
  const progressLabel = modal.querySelector<HTMLDivElement>('#modal-progress-label')!;

  modal.querySelector<HTMLButtonElement>('#close-modal-flasher')!.onclick = () => modal.close();

  // Load identity from backend
  try {
    appendModalLog(`[API] Mengambil kredensial identitas untuk SN: ${sn}...\n`);
    const idRes = await api(`/devices/${encodeURIComponent(sn)}/identity`);
    modalIdentity = idRes;
    idStatus.textContent = `✓ Identitas terverifikasi (Model: ${idRes.model}, HW: ${idRes.hardware_version}, MQTT: ${idRes.mqtt_host})`;
    idStatus.style.color = 'var(--primary)';
    idPreview.textContent = JSON.stringify(idRes, null, 2);
    dlIdBtn.disabled = false;
    appendModalLog(`[API] Identitas ${sn} siap disuntikkan.\n`);
  } catch (err: any) {
    idStatus.textContent = `⚠️ Gagal memuat identitas: ${err?.message || err}`;
    idStatus.style.color = '#e74c3c';
    appendModalLog(`[Error] Gagal memuat identitas: ${err?.message || err}\n`);
  }

  dlIdBtn.onclick = () => {
    if (modalIdentity) downloadFile('identity.json', JSON.stringify(modalIdentity, null, 2) + '\n');
  };
  dlCaBtn.onclick = () => {
    downloadFile('ca.pem', ISRG_ROOT_X1_CA + '\n');
  };

  modal.querySelectorAll<HTMLInputElement>('input[name="modal-fw-source"]').forEach(r => {
    r.onchange = () => {
      const isServer = (modal.querySelector('input[name="modal-fw-source"]:checked') as HTMLInputElement)?.value === 'server';
      modal.querySelector<HTMLDivElement>('#modal-server-container')!.style.display = isServer ? 'block' : 'none';
      modal.querySelector<HTMLDivElement>('#modal-custom-container')!.style.display = isServer ? 'none' : 'block';
    };
  });

  modal.querySelector<HTMLButtonElement>('#modal-clear-log-btn')!.onclick = () => {
    modalLogText = '';
    terminalBox.textContent = '';
  };

  // Connect USB
  connBtn.onclick = async () => {
    try {
      connBtn.disabled = true;
      const info = await flasher.connect(115200, appendModalLog);
      connectedChipInfo = info;
      connPill.className = 'flasher-status-pill connected';
      connPill.textContent = `🔌 Terhubung: ${info.chip} ${info.flashSize ? '(' + info.flashSize + ')' : ''}`;
      connBtn.style.display = 'none';
      disconnBtn.style.display = 'inline-flex';
      notice(`ESP Terhubung: ${info.chip}`);
    } catch (e: any) {
      appendModalLog(`Error koneksi USB: ${e?.message || e}\n`);
      notice(String(e?.message || e), true);
    } finally {
      connBtn.disabled = false;
    }
  };

  // Disconnect USB
  disconnBtn.onclick = async () => {
    await flasher.disconnect();
    connectedChipInfo = null;
    connPill.className = 'flasher-status-pill disconnected';
    connPill.textContent = '🔌 USB: Belum Terhubung';
    connBtn.style.display = 'inline-flex';
    disconnBtn.style.display = 'none';
    appendModalLog('Port USB diputuskan.\n');
  };

  // Start Flash & Auto-Inject
  flashBtn.onclick = async () => {
    if (!flasher.getConnected()) {
      alert('Sambungkan port USB ESP terlebih dahulu (klik tombol "Hubungkan USB").');
      return;
    }

    const isServer = (modal.querySelector('input[name="modal-fw-source"]:checked') as HTMLInputElement)?.value === 'server';
    const serverSelect = modal.querySelector<HTMLSelectElement>('#modal-server-fw');
    const customFileInput = modal.querySelector<HTMLInputElement>('#modal-custom-file');

    let fwData: Uint8Array | null = null;
    let fwAddress = 0x00000;
    if (connectedChipInfo?.chip?.toUpperCase().includes('ESP32')) {
      fwAddress = 0x10000;
    }

    try {
      flashBtn.disabled = true;
      progressWrap.style.display = 'block';

      if (isServer) {
        const url = serverSelect?.value;
        if (!url) throw new Error('Pilih firmware resmi server terlebih dahulu atau gunakan upload firmware sendiri.');
        appendModalLog(`[Download] Mengunduh binary firmware dari server (${url})...\n`);
        const res = await fetch(url);
        if (!res.ok) throw new Error(`Gagal mengunduh firmware (${res.status} ${res.statusText})`);
        fwData = new Uint8Array(await res.arrayBuffer());
        appendModalLog(`[Download] Ukuran firmware: ${fwData.length} bytes.\n`);
      } else {
        const file = customFileInput?.files?.[0];
        if (!file) throw new Error('Pilih file binary firmware (.bin) Anda terlebih dahulu.');
        appendModalLog(`[File] Membaca file ${file.name} (${file.size} bytes)...\n`);
        fwData = new Uint8Array(await file.arrayBuffer());
      }

      const filesToFlash = [{ data: fwData, address: fwAddress }];
      appendModalLog(`\n[Flash] Memulai penulisan ROM pada offset 0x${fwAddress.toString(16).toUpperCase()}...\n`);

      await flasher.flash(
        filesToFlash,
        (percent, msg) => {
          progressBar.style.width = `${percent}%`;
          progressLabel.textContent = msg;
        },
        appendModalLog
      );

      // Auto-Inject Identity!
      if (modalIdentity) {
        appendModalLog(`\n[Auto-Inject] Menyuntikkan kredensial identitas ke perangkat ${sn}...\n`);
        const injected = await flasher.injectIdentity(JSON.stringify(modalIdentity), appendModalLog);
        if (injected) {
          appendModalLog(`\n✅ SUKSES: Perangkat ${sn} telah berhasil diprogram dan identitasnya aktif!\n`);
          notice(`Perangkat ${sn} berhasil di-flash & diinisialisasi!`);
        }
      } else {
        appendModalLog(`\n⚠️ Flash selesai, namun identitas tidak ditemukan untuk diinjeksi.\n`);
      }
    } catch (err: any) {
      appendModalLog(`\n[ERROR FLASHING]: ${err?.message || err}\n`);
      notice(String(err?.message || err), true);
    } finally {
      flashBtn.disabled = false;
    }
  };
}

// Attach Flasher UI Events
function attachFlasherEvents(devices: Row[]) {
  const deviceSelect = document.querySelector<HTMLSelectElement>('#flasher-device-select');
  const identityDetails = document.querySelector<HTMLDivElement>('#flasher-identity-details');
  const preview = document.querySelector<HTMLPreElement>('#identity-json-preview');
  const downloadIdentityBtn = document.querySelector<HTMLButtonElement>('#download-identity-btn');
  const downloadCaBtn = document.querySelector<HTMLButtonElement>('#download-ca-btn');

  const fwSourceRadios = document.querySelectorAll<HTMLInputElement>('input[name="fw-source"]');
  const serverFwContainer = document.querySelector<HTMLDivElement>('#server-fw-container');
  const customFwContainer = document.querySelector<HTMLDivElement>('#custom-fw-container');

  const connectBtn = document.querySelector<HTMLButtonElement>('#flasher-connect-btn');
  const disconnectBtn = document.querySelector<HTMLButtonElement>('#flasher-disconnect-btn');
  const startBtn = document.querySelector<HTMLButtonElement>('#flasher-start-btn');
  const clearLogBtn = document.querySelector<HTMLButtonElement>('#flasher-clear-log');
  const baudSelect = document.querySelector<HTMLSelectElement>('#flasher-baudrate');
  const connectionPill = document.querySelector<HTMLSpanElement>('#flasher-connection-pill');

  const progressWrapper = document.querySelector<HTMLDivElement>('#flasher-progress-wrapper');
  const progressBar = document.querySelector<HTMLDivElement>('#flasher-progress-bar');
  const progressLabel = document.querySelector<HTMLDivElement>('#flasher-progress-label');

  // Load identity when device is selected
  async function loadSelectedDevice(sn: string) {
    selectedFlasherSn = sn;
    if (!sn) {
      loadedIdentity = null;
      if (identityDetails) identityDetails.style.display = 'none';
      return;
    }
    try {
      appendFlasherLog(`Mengambil identitas kredensial perangkat ${sn} dari backend...\n`);
      const res = await api(`/devices/${encodeURIComponent(sn)}/identity`);
      loadedIdentity = res;
      if (identityDetails) identityDetails.style.display = 'block';
      if (preview) preview.textContent = JSON.stringify(res, null, 2);
      appendFlasherLog(`Identitas ${sn} siap untuk diprogram.\n`);
    } catch (err) {
      appendFlasherLog(`Gagal memuat identitas ${sn}: ${err}\n`);
    }
  }

  deviceSelect?.addEventListener('change', () => {
    void loadSelectedDevice(deviceSelect.value);
  });

  if (selectedFlasherSn && !loadedIdentity) {
    void loadSelectedDevice(selectedFlasherSn);
  }

  downloadIdentityBtn?.addEventListener('click', () => {
    if (!loadedIdentity) return;
    downloadFile('identity.json', JSON.stringify(loadedIdentity, null, 2) + '\n');
  });

  downloadCaBtn?.addEventListener('click', () => {
    downloadFile('ca.pem', ISRG_ROOT_X1_CA + '\n');
  });

  fwSourceRadios.forEach(radio => {
    radio.addEventListener('change', () => {
      const isServer = (document.querySelector('input[name="fw-source"]:checked') as HTMLInputElement)?.value === 'server';
      if (serverFwContainer) serverFwContainer.style.display = isServer ? 'block' : 'none';
      if (customFwContainer) customFwContainer.style.display = isServer ? 'none' : 'block';
    });
  });

  clearLogBtn?.addEventListener('click', () => {
    flasherLogText = '';
    const box = document.querySelector<HTMLDivElement>('#flasher-terminal-box');
    if (box) box.textContent = '';
  });

  // Connect USB
  connectBtn?.addEventListener('click', async () => {
    const baud = Number(baudSelect?.value || 115200);
    try {
      connectBtn.disabled = true;
      const info = await flasher.connect(baud, appendFlasherLog);
      connectedChipInfo = info;
      if (connectionPill) {
        connectionPill.className = 'flasher-status-pill connected';
        connectionPill.textContent = `🔌 Terhubung: ${info.chip} ${info.flashSize ? '(' + info.flashSize + ')' : ''}`;
      }
      if (connectBtn) connectBtn.style.display = 'none';
      if (disconnectBtn) disconnectBtn.style.display = 'inline-flex';
      notice(`ESP Berhasil terhubung: ${info.chip}`);
    } catch (err) {
      appendFlasherLog(`Error koneksi: ${err}\n`);
      notice(String(err), true);
    } finally {
      if (connectBtn) connectBtn.disabled = false;
    }
  });

  // Disconnect USB
  disconnectBtn?.addEventListener('click', async () => {
    await flasher.disconnect();
    connectedChipInfo = null;
    if (connectionPill) {
      connectionPill.className = 'flasher-status-pill disconnected';
      connectionPill.textContent = '🔌 USB: Belum Terhubung';
    }
    if (connectBtn) connectBtn.style.display = 'inline-flex';
    if (disconnectBtn) disconnectBtn.style.display = 'none';
    appendFlasherLog('Port USB diputuskan.\n');
  });

  // Start Flashing
  startBtn?.addEventListener('click', async () => {
    if (!flasher.getConnected()) {
      alert('Sambungkan perangkat ESP via USB terlebih dahulu (Klik tombol "Hubungkan ke ESP").');
      return;
    }

    const isServer = (document.querySelector('input[name="fw-source"]:checked') as HTMLInputElement)?.value === 'server';
    const serverFwSelect = document.querySelector<HTMLSelectElement>('#flasher-server-fw');
    const customFileInput = document.querySelector<HTMLInputElement>('#flasher-custom-file');

    let fwData: Uint8Array | null = null;
    let fwAddress = 0x00000;

    // Detect default offset based on chip
    if (connectedChipInfo?.chip?.toUpperCase().includes('ESP32')) {
      fwAddress = 0x10000;
    }

    try {
      startBtn.disabled = true;
      if (progressWrapper) progressWrapper.style.display = 'block';

      if (isServer) {
        const url = serverFwSelect?.value;
        if (!url) throw new Error('Pilih firmware resmi server terlebih dahulu.');
        appendFlasherLog(`Mengunduh binary firmware dari server (${url})...\n`);
        const res = await fetch(url);
        if (!res.ok) throw new Error(`Gagal mengunduh firmware (${res.status} ${res.statusText})`);
        const buf = await res.arrayBuffer();
        fwData = new Uint8Array(buf);
        appendFlasherLog(`Ukuran firmware: ${fwData.length} bytes.\n`);
      } else {
        const file = customFileInput?.files?.[0];
        if (!file) throw new Error('Pilih file binary firmware (.bin) Anda.');
        appendFlasherLog(`Membaca file ${file.name} (${file.size} bytes)...\n`);
        const buf = await file.arrayBuffer();
        fwData = new Uint8Array(buf);
      }

      const filesToFlash: Array<{ data: Uint8Array; address: number }> = [
        { data: fwData, address: fwAddress }
      ];

      appendFlasherLog(`\nMemulai flashing binary firmware ke chip pada offset 0x${fwAddress.toString(16).toUpperCase()}...\n`);
      await flasher.flash(
        filesToFlash,
        (percent, msg) => {
          flasherProgress = percent;
          flasherProgressMsg = msg;
          if (progressBar) progressBar.style.width = `${percent}%`;
          if (progressLabel) progressLabel.textContent = msg;
        },
        appendFlasherLog
      );

      if (loadedIdentity) {
        appendFlasherLog(`\n[Auto-Inject] Menyuntikkan kredensial identitas ke perangkat ${selectedFlasherSn}...\n`);
        const injected = await flasher.injectIdentity(JSON.stringify(loadedIdentity), appendFlasherLog);
        if (injected) {
          appendFlasherLog(`\n✅ SUKSES: Perangkat ${selectedFlasherSn} telah berhasil diprogram dan identitasnya aktif!\n`);
          notice(`Perangkat ${selectedFlasherSn} berhasil di-flash & diinisialisasi!`);
        }
      } else {
        notice('Flashing berhasil! ESP sedang reboot dengan firmware baru.');
        appendFlasherLog('\n*** SELESAI: Perangkat siap digunakan! ***\n');
      }
    } catch (err) {
      appendFlasherLog(`\nERROR FLASHING: ${err}\n`);
      notice(String(err), true);
    } finally {
      startBtn.disabled = false;
    }
  });
}

// Global hard-delete observer for devices & users in superadmin view
const deleteObserver = new MutationObserver(() => {
  if (view !== 'dashboard' || currentUser?.role === 'tenant_admin') return;
  if (page === 'Perangkat') {
    document.querySelectorAll<HTMLButtonElement>('[data-disable]').forEach(toggle => {
      if (toggle.parentElement?.querySelector('[data-hard-delete]')) return;
      const button = document.createElement('button');
      button.dataset.hardDelete = toggle.dataset.disable;
      button.className = 'danger';
      button.textContent = 'Hapus';
      button.onclick = () => void act(async () => {
        const sn = button.dataset.hardDelete!;
        if (prompt(`Ketik SN ${sn} untuk menghapus permanen`) !== sn) return;
        await api(`/admin/devices/${encodeURIComponent(sn)}`, 'DELETE');
        await renderDashboard();
      });
      toggle.parentElement?.append(' ', button);
    });
  }
  if (page === 'Pengguna') {
    document.querySelectorAll<HTMLButtonElement>('[data-user-status]').forEach(toggle => {
      if (toggle.parentElement?.querySelector('[data-user-hard-delete]')) return;
      const button = document.createElement('button');
      button.dataset.userHardDelete = toggle.dataset.userStatus;
      button.className = 'danger';
      button.textContent = 'Hapus';
      button.onclick = () => void act(async () => {
        const id = button.dataset.userHardDelete!;
        if (prompt('Ketik DELETE untuk menghapus pengguna dan seluruh device miliknya') !== 'DELETE') return;
        await api(`/admin/users/${encodeURIComponent(id)}`, 'DELETE');
        await renderDashboard();
      });
      toggle.parentElement?.append(' ', button);
    });
  }
});
deleteObserver.observe(app, { childList: true, subtree: true });

function installDeviceInventoryForm() {
  if (view !== 'dashboard' || currentUser?.role === 'tenant_admin') return;
  const content = document.querySelector('#content');
  const title = document.querySelector('header h1')?.textContent;
  if (!content || title !== 'Perangkat' || content.querySelector('#device-inventory')) return;
  const card = document.createElement('dialog');
  card.className = 'card';
  card.id = 'device-inventory';
  card.innerHTML = `<div style="display:flex;justify-content:space-between;align-items:center;gap:12px"><h2>Tambah perangkat produksi</h2><button type="button" id="close-device-modal" class="secondary">Tutup</button></div><p class="muted">Pilih jenis dan jumlah channel. Untuk relay, GPIO dan mode active-low/high dapat dipilih per channel.</p><form id="device-form"><div class="grid"><label>SN / Device ID<input name="sn" placeholder="ESP-A7F9C231" pattern="[A-Z0-9-]{3,64}" required></label><label>Nama perangkat<input name="name" placeholder="Living Room Light" required></label><label>Jenis perangkat<select name="device_type"><option value="relay">RELAY</option><option value="switch">SWITCH</option><option value="sensor">SENSOR SUHU (DHT11)</option><option value="other">Lainnya</option></select></label><label>Tipe relay<select name="relay_type"><option value="relay_1ch">1 CHANNEL</option><option value="relay_2ch" selected>2 CHANNEL</option><option value="relay_4ch">4 CHANNEL</option><option value="relay_8ch">8 CHANNEL</option></select></label><label>GPIO DHT11<input name="dht11_pin" type="number" min="0" max="39" value="14"></label><label>Model<input name="model" value="ESP-RELAY-2CH" required></label><label>Hardware version<input name="hardware_version" value="1.0" required></label><label>Firmware version<input name="firmware_version" value="1.0.0" required></label></div><div id="channel-config"></div><textarea name="channels" hidden required></textarea><p class="muted">GPIO yang tersedia mengikuti board. Jangan gunakan pin reset, UART, atau pin flash. Active-low berarti relay ON saat level listrik GPIO LOW.</p><button type="submit">Buat inventory</button></form>`;
  content.prepend(card);
  card.querySelector<HTMLButtonElement>('#close-device-modal')!.onclick = () => card.close();
  const typeSelect = card.querySelector<HTMLSelectElement>('[name="device_type"]')!;
  const relaySelect = card.querySelector<HTMLSelectElement>('[name="relay_type"]')!;
  const channelsInput = card.querySelector<HTMLTextAreaElement>('[name="channels"]')!;
  const channelConfig = card.querySelector<HTMLDivElement>('#channel-config')!;
  const pins = [2, 4, 5, 12, 13, 14, 16, 17, 18, 19, 21, 22, 23, 25, 26, 27, 32, 33];
  const renderRelayChannels = (count: number) => {
    const previous = (() => { try { return JSON.parse(channelsInput.value) as Array<{ id: number, pin: number, active_low: boolean }>; } catch { return []; } })();
    channelConfig.innerHTML = Array.from({ length: count }, (_, i) => {
      const old = previous.find(channel => channel.id === i + 1);
      const selectedPin = old?.pin ?? pins[i % pins.length];
      const activeLow = old?.active_low ?? true;
      return `<div class="card" style="margin:12px 0;padding:14px"><strong>Relay ${i + 1}</strong><div class="grid"><label>GPIO / Pin<select data-channel-pin="${i + 1}">${pins.map(pin => `<option value="${pin}" ${pin === selectedPin ? 'selected' : ''}>GPIO ${pin}</option>`).join('')}</select></label><label>Mode relay<select data-channel-active="${i + 1}"><option value="true" ${activeLow ? 'selected' : ''}>Active LOW</option><option value="false" ${!activeLow ? 'selected' : ''}>Active HIGH</option></select></label></div></div>`;
    }).join('');
    channelConfig.querySelectorAll('select').forEach(select => select.addEventListener('change', syncChannels));
  };
  const syncChannels = () => {
    const count = Number(relaySelect.value.split('_')[1]?.replace('ch', '') || 0);
    const channels = Array.from({ length: count }, (_, i) => ({
      id: i + 1,
      pin: Number(channelConfig.querySelector<HTMLSelectElement>(`[data-channel-pin="${i + 1}"]`)?.value),
      name: `Relay ${i + 1}`,
      alias: '',
      type: 'switch',
      active_low: channelConfig.querySelector<HTMLSelectElement>(`[data-channel-active="${i + 1}"]`)?.value === 'true',
    }));
    channelsInput.value = JSON.stringify(channels, null, 2);
  };
  const syncRelayChannels = () => {
    const count = Number(relaySelect.value.split('_')[1]?.replace('ch', '') || 0);
    relaySelect.disabled = typeSelect.value === 'other' || typeSelect.value === 'sensor';
    const dhtPin = card.querySelector<HTMLInputElement>('[name="dht11_pin"]')!;
    dhtPin.disabled = typeSelect.value !== 'sensor';
    if (typeSelect.value === 'sensor') {
      channelsInput.value = JSON.stringify([{ id: 1, pin: Number(dhtPin.value || 14), name: 'DHT11', alias: '', type: 'sensor', active_low: false }], null, 2);
      const model = card.querySelector<HTMLInputElement>('[name="model"]');
      if (model) model.value = 'ESP-DHT11';
      return;
    }
    if (typeSelect.value === 'other') return;
    renderRelayChannels(count);
    syncChannels();
    const model = card.querySelector<HTMLInputElement>('[name="model"]');
    if (model && typeSelect.value === 'relay') model.value = `ESP-RELAY-${count}CH`;
  };
  typeSelect.onchange = syncRelayChannels;
  relaySelect.onchange = syncRelayChannels;
  card.querySelector<HTMLInputElement>('[name="dht11_pin"]')!.oninput = syncRelayChannels;
  syncRelayChannels();
  card.querySelector<HTMLFormElement>('#device-form')!.onsubmit = event => {
    event.preventDefault();
    const form = event.currentTarget as HTMLFormElement;
    const values = data(form);
    void act(async () => {
      let channels: unknown;
      try { channels = JSON.parse(String(values.channels)); } catch { throw new Error('Channels JSON tidak valid.'); }
      const result = await api('/admin/devices', 'POST', {
        sn: values.sn,
        name: values.name,
        model: values.model,
        device_type: values.device_type,
        relay_type: values.device_type === 'relay' || values.device_type === 'switch' ? values.relay_type : null,
        ...(values.device_type === 'sensor' ? { dht11_pin: Number(values.dht11_pin) } : {}),
        hardware_version: values.hardware_version,
        firmware_version: values.firmware_version,
        capabilities: values.device_type === 'sensor'
          ? { temperature: true, humidity: true, sensor_type: 'dht11' }
          : { switch: Array.isArray(channels) ? channels.length : 0 },
        channels,
      });
      const credentials = result.production_credentials;
      const identity = {
        sn: credentials.sn,
        device_key: credentials.device_key,
        setup_code: credentials.setup_code,
        model: values.model,
        device_type: values.device_type,
        relay_type: values.device_type === 'relay' || values.device_type === 'switch' ? values.relay_type : null,
        ...(values.device_type === 'sensor' ? { dht11_pin: Number(values.dht11_pin) } : {}),
        hardware_version: values.hardware_version,
        mqtt_host: 'mqtt.rizbill.my.id',
        mqtt_port: 8883,
        reset_pin: 0,
        channels,
      };
      sessionIdentities.set(String(credentials.sn), identity);
      const dialog = document.createElement('dialog');
      dialog.innerHTML = `<h2>Credential produksi</h2><p>Simpan data ini sekarang. Backend tidak menyediakan endpoint untuk mengambil ulang credential ini.</p><label>SN<input readonly value="${esc(credentials.sn)}"></label><label>Device key<input readonly value="${esc(credentials.device_key)}"></label><label>Setup code<input readonly value="${esc(credentials.setup_code)}"></label><div class="dialog-actions"><button id="download-identity">Download identity.json</button><button id="download-label" class="secondary">Download setup-label.txt</button> <button id="close-dialog" class="secondary">Tutup</button></div>`;
      document.body.append(dialog);
      dialog.querySelector<HTMLButtonElement>('#download-identity')!.onclick = () => downloadFile('identity.json', JSON.stringify(identity, null, 2) + '\n');
      dialog.querySelector<HTMLButtonElement>('#download-label')!.onclick = () => downloadFile('setup-label.txt', `SN: ${credentials.sn}\nSSID: RIZIO-${String(credentials.sn).slice(-8)}\nSetup/AP password: ${credentials.setup_code}\n`);
      dialog.querySelector<HTMLButtonElement>('#close-dialog')!.onclick = () => dialog.remove();
      dialog.showModal();
      await renderDashboard();
    });
  };
}

const inventoryObserver = new MutationObserver(() => installDeviceInventoryForm());
inventoryObserver.observe(app, { childList: true, subtree: true });

// Initialize app session
void restoreSession();
