import './style.css';
import QRCode from 'qrcode';
type Row = Record<string, any>;
const app = document.querySelector<HTMLDivElement>('#app')!;
let access = '', refresh = '', page = 'Dashboard', busy = false;
const sessionIdentities = new Map<string, Row>();
let base = localStorage.getItem('rizio_api') || '/v1';
let refreshWork: Promise<void> | undefined;
const esc = (v: unknown) => String(v ?? 'â€”').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
async function api(path: string, method = 'GET', body?: unknown, retry = true): Promise<any> {
  const response = await fetch(base + path, { method, headers: { 'Content-Type': 'application/json', ...(access ? { Authorization: `Bearer ${access}` } : {}) }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  if (response.status === 401 && refresh && retry) {
    refreshWork ??= api('/auth/refresh', 'POST', {refresh_token: refresh}, false).then(d => {access=d.access_token; refresh=d.refresh_token;}).finally(()=>{refreshWork=undefined;});
    try { await refreshWork; } catch(e) {access='';refresh='';login();throw e;}
    return api(path, method, body, false);
  }
  const result = await response.json();
  if (!response.ok || result.status === 'error') throw new Error(result.message || 'Permintaan gagal');
  return result.data;
}
async function restoreSession() {
  refresh = sessionStorage.getItem('rizio_refresh') || '';
  if (!refresh) { login(); return; }
  try { await api('/auth/refresh', 'POST', {refresh_token: refresh}, false).then(d => { access = d.access_token; refresh = d.refresh_token; sessionStorage.setItem('rizio_refresh', refresh); }); await render(); }
  catch { access = ''; refresh = ''; sessionStorage.removeItem('rizio_refresh'); login(); }
}
function notice(message: string, error=false) { const target=document.querySelector('#notice'); if(target) {target.className=`notice ${error?'error':''}`;target.textContent=message;} }
function data(form: HTMLFormElement): Row { return Object.fromEntries(new FormData(form).entries()); }
function downloadFile(filename: string, value: string) { const link = document.createElement('a'); link.href = URL.createObjectURL(new Blob([value], {type:'text/plain;charset=utf-8'})); link.download = filename; link.click(); URL.revokeObjectURL(link.href); }
async function showClaimQr(sn: string) { const value = `ESPCTRL://device?sn=${encodeURIComponent(sn)}`; const image = await QRCode.toDataURL(value, {width:280, margin:2}); const dialog=document.createElement('dialog'); dialog.innerHTML=`<h2>QR perangkat · ${esc(sn)}</h2><img src="${image}" alt="QR perangkat ${esc(sn)}" style="width:280px;height:280px;display:block;margin:16px auto"><p>${esc(value)}</p><button onclick="window.print()">Print</button> <button>Tutup</button>`; document.body.append(dialog); dialog.querySelectorAll('button')[1].onclick=()=>dialog.remove(); dialog.showModal(); }
function login() {
 app.innerHTML=`<section class="card login"><h1>RizIO<span style="color:#299d89">.</span></h1><p>Ruang kendali administrator</p><form id="login"><label>Alamat API<input name="base" value="${esc(base)}" required></label><label>Email<input name="email" type="email" autocomplete="username" required></label><label>Kata sandi<input name="password" type="password" autocomplete="current-password" required></label><button>Masuk</button></form><div id="notice" role="status"></div><p class="muted">Sesi bertahan saat halaman di-reload dan berakhir saat tab ditutup.</p></section>`;
 document.querySelector<HTMLFormElement>('form')!.onsubmit=async e=>{e.preventDefault();const f=e.currentTarget as HTMLFormElement;const d=data(f);base=String(d.base).replace(/\/$/,'');if(!base.startsWith('/')&&!base.startsWith('https://')&&!/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?\/v1$/.test(base)){notice('Gunakan URL HTTPS atau /v1.',true);return;}localStorage.setItem('rizio_api',base);const button=f.querySelector('button')!;button.disabled=true;try{const r=await api('/auth/login','POST',{email:d.email,password:d.password});if(r.user.role!=='admin')throw new Error('Akun administrator diperlukan.');access=r.access_token;refresh=r.refresh_token;sessionStorage.setItem('rizio_refresh',refresh);await render();}catch(e){notice(String(e),true);button.disabled=false;}};
}
const pages=['Dashboard','Pengguna','Perangkat','Online','Offline','Firmware','OTA','Perintah','Log','Sistem'];
function rows(value:any):Row[]{return Array.isArray(value)?value:value?.items||value?.devices||value?.users||value?.firmwares||value?.commands||value?.logs||[];}
function table(items:Row[],columns:string[],action?:(r:Row)=>string):string{const deviceColumns=columns.includes('owner_user_id')&&columns.includes('firmware_version')?['sn','name','device_type','relay_type','model','channels','firmware_version','owner_user_id','online','disabled','last_seen']:columns;return items.length?`<div class="table"><table><thead><tr>${deviceColumns.map(c=>`<th>${esc(c.replaceAll('_',' '))}</th>`).join('')}${action?'<th>Tindakan</th>':''}</tr></thead><tbody>${items.map(r=>`<tr>${deviceColumns.map(c=>`<td>${esc(typeof r[c]==='object'?JSON.stringify(r[c]):r[c])}</td>`).join('')}${action?`<td>${action(r)}</td>`:''}</tr>`).join('')}</tbody></table></div>`:'<p>Belum ada data.</p>';}
async function render(){
 app.innerHTML=`<div class="shell"><aside><h2>RizIO.</h2><nav>${pages.map(p=>`<button data-page="${p}" class="${p===page?'active':''}">${p}</button>`).join('')}</nav></aside><main><header><div><div class="muted">ADMINISTRATOR / RIZIO CLOUD</div><h1>${page}</h1></div><div class="toolbar">${page==='Perangkat'?'<button id="add-device">+ Tambah perangkat</button>':''}<button id="reload" class="secondary">Perbarui</button><button id="logout" class="secondary">Keluar</button></div></header><div id="notice" role="status"></div><section id="content" aria-live="polite"><p>Memuat dataâ€¦</p></section></main></div>`;
 document.querySelectorAll<HTMLButtonElement>('[data-page]').forEach(b=>b.onclick=()=>{page=b.dataset.page!;void render();});
 document.querySelector<HTMLButtonElement>('#reload')!.onclick=()=>void render();
 document.querySelector<HTMLButtonElement>('#add-device')?.addEventListener('click',()=>{const form=document.querySelector('#device-form');form?.scrollIntoView({behavior:'smooth',block:'start'});(form?.querySelector('[name="sn"]') as HTMLInputElement|undefined)?.focus();});
 document.querySelector<HTMLButtonElement>('#logout')!.onclick=async()=>{try{await api('/auth/logout','POST',{refresh_token:refresh});}catch{}access='';refresh='';sessionStorage.removeItem('rizio_refresh');login();};
 const currentPage=page;const content=document.querySelector('#content')!;
 try {
  if(page==='Dashboard') {const s=await api('/admin/summary');content.innerHTML=`<div class="stats">${Object.entries(s).filter(([,v])=>typeof v!=='object').map(([k,v])=>`<div class="card stat"><span class="muted">${esc(k.replaceAll('_',' '))}</span><strong>${esc(v)}</strong></div>`).join('')}</div><div class="card"><h2>Distribusi firmware & koneksi</h2><pre>${esc(JSON.stringify(s,null,2))}</pre></div>`;}
  else if(page==='Pengguna') {const users=rows(await api('/admin/users'));content.innerHTML=`<div class="card"><h2>Tambah pengguna</h2><form id="user-form" class="grid"><label>Nama<input name="name" required></label><label>Email<input name="email" type="email" required></label><label>Password<input name="password" type="password" minlength="12" required></label><button>Tambah pengguna</button></form></div><div class="card">${table(users,['name','email','role','status','claimed_devices','created_at'],r=>`<button data-user-status="${esc(r.id)}" data-value="${r.status!=='active'}" class="secondary">${r.status==='active'?'Nonaktifkan':'Aktifkan'}</button>`)}</div>`;document.querySelector<HTMLFormElement>('#user-form')!.onsubmit=e=>{e.preventDefault();const values=data(e.currentTarget as HTMLFormElement);void act(async()=>{await api('/admin/users','POST',{name:values.name,email:values.email,password:values.password});await render();});};document.querySelectorAll<HTMLButtonElement>('[data-user-status]').forEach(b=>b.onclick=()=>void act(async()=>{await api('/admin/users/'+encodeURIComponent(b.dataset.userStatus!),'PATCH',{status:b.dataset.value==='true'?'active':'disabled'});await render();}));}
  else if(['Perangkat','Online','Offline'].includes(page)) {let devices=rows(await api('/admin/devices'));if(page==='Online')devices=devices.filter(d=>d.online);if(page==='Offline')devices=devices.filter(d=>!d.online);content.innerHTML=`<div class="card">${table(devices,['sn','name','model','firmware_version','owner_user_id','online','disabled','last_seen'],r=>`<button data-qr="${esc(r.sn)}" class="secondary">View QR</button> <button data-info="${esc(r.sn)}" class="secondary">Telemetri</button> <button data-identity="${esc(r.sn)}" class="secondary">View identity.json</button> <button data-edit="${esc(r.sn)}" class="secondary">Edit</button> <button data-disable="${esc(r.sn)}" data-value="${!r.disabled}">${r.disabled?'Aktifkan':'Nonaktifkan'}</button>`)}</div>`;document.querySelectorAll<HTMLButtonElement>('[data-qr]').forEach(b=>b.onclick=()=>showClaimQr(b.dataset.qr!));document.querySelectorAll<HTMLButtonElement>('[data-identity]').forEach(b=>b.onclick=()=>{const identity=sessionIdentities.get(b.dataset.identity!);const dialog=document.createElement('dialog');dialog.innerHTML=identity?`<h2>identity.json · ${esc(b.dataset.identity)}</h2><pre>${esc(JSON.stringify(identity,null,2))}</pre><button id="download">Download</button> <button>Tutup</button>`:`<h2>identity.json tidak tersedia</h2><p>Device key hanya ditampilkan saat inventory dibuat dan tidak dapat diambil ulang dari backend.</p><button>Tutup</button>`;document.body.append(dialog);const buttons=dialog.querySelectorAll<HTMLButtonElement>('button');if(identity)buttons[0].onclick=()=>downloadFile('identity.json',JSON.stringify(identity,null,2)+'\n');buttons[buttons.length-1].onclick=()=>dialog.remove();dialog.showModal();});document.querySelectorAll<HTMLButtonElement>('[data-edit]').forEach(b=>b.onclick=()=>act(async()=>{const device=devices.find(d=>d.sn===b.dataset.edit);const name=prompt('Nama perangkat:',device?.name||'');if(name&&name.trim()&&name.trim()!==device?.name){await api('/admin/devices/'+encodeURIComponent(b.dataset.edit!),'PATCH',{name:name.trim()});await render();}}));document.querySelectorAll<HTMLButtonElement>('[data-disable]').forEach(b=>b.onclick=()=>act(async()=>{if(!confirm(`${b.textContent} ${b.dataset.disable}?`))return;await api('/admin/devices/'+encodeURIComponent(b.dataset.disable!),'PATCH',{disabled:b.dataset.value==='true'});await render();}));document.querySelectorAll<HTMLButtonElement>('[data-info]').forEach(b=>b.onclick=()=>{const device=devices.find(d=>d.sn===b.dataset.info);const dialog=document.createElement('dialog');dialog.innerHTML=`<h2>Telemetri ${esc(device?.sn)}</h2><pre>${esc(JSON.stringify(device,null,2))}</pre><button>Tutup</button>`;document.body.append(dialog);dialog.querySelector('button')!.onclick=()=>dialog.remove();dialog.showModal();});}
  else if(page==='Firmware') {content.innerHTML=`<div class="card"><h2>Daftarkan firmware</h2><form id="firmware"><div class="grid">${['model','hardware_version','version','url','checksum','file_size'].map(n=>`<label>${n}<input name="${n}" required ${n==='file_size'?'type="number" min="1"':n==='url'?'type="url"':''}></label>`).join('')}</div><label>Catatan rilis<textarea name="release_notes"></textarea></label><button>Daftarkan</button></form><p class="muted">Unggah binary ke hosting HTTPS Anda, lalu masukkan URL dan SHA256. Pilih file untuk menghitung checksum dan ukuran.</p><input id="binary" type="file" accept=".bin"><button id="upload">Unggah binary ke server</button></div><div class="card">${table(rows(await api('/admin/firmwares')),['id','model','hardware_version','version','file_size','is_active'])}</div>`;document.querySelector<HTMLInputElement>('#binary')!.onchange=async e=>{const file=(e.target as HTMLInputElement).files?.[0];if(!file)return;const hash=await crypto.subtle.digest('SHA-256',await file.arrayBuffer());(document.querySelector('[name="checksum"]') as HTMLInputElement).value=Array.from(new Uint8Array(hash)).map(b=>b.toString(16).padStart(2,'0')).join('');(document.querySelector('[name="file_size"]') as HTMLInputElement).value=String(file.size);};document.querySelector<HTMLButtonElement>('#upload')!.onclick=()=>act(async()=>{const f=document.querySelector<HTMLFormElement>('#firmware')!;const binary=document.querySelector<HTMLInputElement>('#binary')!.files?.[0];if(!binary)throw new Error('Pilih file binary terlebih dahulu.');const body=new FormData();body.set('file',binary);for(const key of ['model','hardware_version','version','release_notes'])body.set(key,String(data(f)[key]||''));const r=await fetch(base+'/admin/firmwares/upload',{method:'POST',headers:{Authorization:'Bearer '+access},body});const result=await r.json();if(!r.ok)throw new Error(result.message||'Upload gagal');await render();notice('Binary firmware tersimpan.');});document.querySelector<HTMLFormElement>('#firmware')!.onsubmit=e=>{e.preventDefault();const d=data(e.currentTarget as HTMLFormElement);act(async()=>{await api('/admin/firmwares','POST',{...d,file_size:Number(d.file_size)});await render();notice('Metadata firmware disimpan.');});};}
  else if(page==='OTA') {const [ds,fs]=await Promise.all([api('/admin/devices'),api('/admin/firmwares')]);content.innerHTML=`<div class="card"><h2>Deployment firmware</h2><form id="ota"><label>Perangkat<select name="sn">${rows(ds).map(d=>`<option value="${esc(d.sn)}">${esc(d.name||d.sn)} Â· ${esc(d.model)} / ${esc(d.hardware_version)}</option>`).join('')}</select></label><label>Firmware<select name="firmware_id">${rows(fs).map(f=>`<option value="${esc(f.id)}">${esc(f.model)} / ${esc(f.hardware_version)} Â· ${esc(f.version)}</option>`).join('')}</select></label><button>Kirim OTA</button></form><p class="muted">Pantau ACK pada menu Perintah dan versi perangkat sesudah restart.</p></div>`;document.querySelector<HTMLFormElement>('#ota')!.onsubmit=e=>{e.preventDefault();const d=data(e.currentTarget as HTMLFormElement);act(async()=>{if(!confirm('Kirim pembaruan firmware ke perangkat ini?'))return;const r=await api('/admin/devices/'+encodeURIComponent(d.sn)+'/ota','POST',{firmware_id:d.firmware_id});notice(`OTA diantrikan. ID: ${r.request_id}. Menunggu konfirmasi perangkat.`);});};}
  else if(page==='Perintah')content.innerHTML=`<div class="card">${table(rows(await api('/admin/commands')),['request_id','sn','command','command_status','created_at','ack_at'])}</div>`;
  else if(page==='Log')content.innerHTML=`<div class="card">${table(rows(await api('/admin/logs')),['sn','event_type','payload','created_at'])}</div>`;
  else {const r=await fetch(base.replace(/\/v1$/,'')+'/health');content.innerHTML=`<div class="card"><h2>Kesehatan layanan</h2><pre>${esc(JSON.stringify(await r.json(),null,2))}</pre></div>`;}
 }catch(e){if(currentPage===page) {content.innerHTML='<div class="card"><p>Data tidak dapat dimuat. Gunakan Perbarui untuk mencoba kembali.</p></div>';notice(String(e),true);}}
}
async function act(work:()=>Promise<void>){if(busy)return;busy=true;document.querySelectorAll<HTMLButtonElement>('main button').forEach(b=>b.disabled=true);try{await work();}catch(e){notice(String(e),true);}finally{busy=false;document.querySelectorAll<HTMLButtonElement>('main button').forEach(b=>b.disabled=false);}}
const deleteObserver = new MutationObserver(() => {
  if (page === 'Perangkat') {
    document.querySelectorAll<HTMLButtonElement>('[data-disable]').forEach(toggle => {
      if (toggle.parentElement?.querySelector('[data-hard-delete]')) return;
      const button = document.createElement('button');
      button.dataset.hardDelete = toggle.dataset.disable;
      button.className = 'danger';
      button.textContent = 'Hapus permanen';
      button.onclick = () => void act(async () => {
        const sn = button.dataset.hardDelete!;
        if (prompt(`Ketik SN ${sn} untuk menghapus permanen`) !== sn) return;
        await api(`/admin/devices/${encodeURIComponent(sn)}`, 'DELETE');
        await render();
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
      button.textContent = 'Hapus permanen';
      button.onclick = () => void act(async () => {
        const id = button.dataset.userHardDelete!;
        if (prompt('Ketik DELETE untuk menghapus pengguna dan seluruh device miliknya') !== 'DELETE') return;
        await api(`/admin/users/${encodeURIComponent(id)}`, 'DELETE');
        await render();
      });
      toggle.parentElement?.append(' ', button);
    });
  }
});
deleteObserver.observe(app, {childList: true, subtree: true});
void restoreSession();

function installDeviceInventoryForm() {
  const content = document.querySelector('#content');
  const title = document.querySelector('header h1')?.textContent;
  if (!content || title !== 'Perangkat' || content.querySelector('#device-inventory')) return;
  const card = document.createElement('section');
  card.className = 'card';
  card.id = 'device-inventory';
  card.innerHTML = `<h2>Tambah perangkat produksi</h2><p class="muted">Pilih jenis dan jumlah channel. Untuk relay, GPIO dan mode active-low/high dapat dipilih per channel.</p><form id="device-form"><div class="grid"><label>SN / Device ID<input name="sn" placeholder="ESP-A7F9C231" pattern="[A-Z0-9-]{3,64}" required></label><label>Nama perangkat<input name="name" placeholder="Living Room Light" required></label><label>Jenis perangkat<select name="device_type"><option value="relay">RELAY</option><option value="switch">SWITCH</option><option value="sensor">SENSOR SUHU (DHT11)</option><option value="other">Lainnya</option></select></label><label>Tipe relay<select name="relay_type"><option value="relay_1ch">1 CHANNEL</option><option value="relay_2ch" selected>2 CHANNEL</option><option value="relay_4ch">4 CHANNEL</option><option value="relay_8ch">8 CHANNEL</option></select></label><label>GPIO DHT11<input name="dht11_pin" type="number" min="0" max="39" value="14"></label><label>Model<input name="model" value="ESP-RELAY-2CH" required></label><label>Hardware version<input name="hardware_version" value="1.0" required></label><label>Firmware version<input name="firmware_version" value="1.0.0" required></label></div><div id="channel-config"></div><textarea name="channels" hidden required></textarea><p class="muted">GPIO yang tersedia mengikuti board. Jangan gunakan pin reset, UART, atau pin flash. Active-low berarti relay ON saat level listrik GPIO LOW.</p><button type="submit">Buat inventory</button></form>`;
  content.prepend(card);
  const typeSelect = card.querySelector<HTMLSelectElement>('[name="device_type"]')!;
  const relaySelect = card.querySelector<HTMLSelectElement>('[name="relay_type"]')!;
  const channelsInput = card.querySelector<HTMLTextAreaElement>('[name="channels"]')!;
  const channelConfig = card.querySelector<HTMLDivElement>('#channel-config')!;
  const pins = [2, 4, 5, 12, 13, 14, 16, 17, 18, 19, 21, 22, 23, 25, 26, 27, 32, 33];
  const renderRelayChannels = (count: number) => {
    const previous = (() => { try { return JSON.parse(channelsInput.value) as Array<{id:number,pin:number,active_low:boolean}>; } catch { return []; } })();
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
      dialog.innerHTML = `<h2>Credential produksi</h2><p>Simpan data ini sekarang. Backend tidak menyediakan endpoint untuk mengambil ulang credential ini.</p><label>SN<input readonly value="${esc(credentials.sn)}"></label><label>Device key<input readonly value="${esc(credentials.device_key)}"></label><label>Setup code<input readonly value="${esc(credentials.setup_code)}"></label><div class="dialog-actions"><button id="download-identity">Download identity.json</button><button id="download-label" class="secondary">Download setup-label.txt</button></div><button id="close-dialog" class="secondary">Tutup</button>`;
      document.body.append(dialog);
      dialog.querySelector<HTMLButtonElement>('#download-identity')!.onclick = () => downloadFile('identity.json', JSON.stringify(identity, null, 2) + '\n');
      dialog.querySelector<HTMLButtonElement>('#download-label')!.onclick = () => downloadFile('setup-label.txt', `SN: ${credentials.sn}\nSSID: RIZIO-${String(credentials.sn).slice(-8)}\nSetup/AP password: ${credentials.setup_code}\n`);
      dialog.querySelector<HTMLButtonElement>('#close-dialog')!.onclick = () => dialog.remove();
      dialog.showModal();
      await render();
    });
  };
}

const inventoryObserver = new MutationObserver(() => installDeviceInventoryForm());
inventoryObserver.observe(app, { childList: true, subtree: true });
