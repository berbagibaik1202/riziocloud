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
async function showClaimQr(sn: string) { const identity = sessionIdentities.get(sn); if (!identity) { alert('QR claim hanya dapat dibuat saat inventory dibuat, karena claim code tidak dapat diambil ulang.'); return; } const claim = `ESPCTRL://claim?sn=${encodeURIComponent(sn)}&code=${encodeURIComponent(identity.claim_code || '')}`; const image = await QRCode.toDataURL(claim, {width:280, margin:2}); const dialog=document.createElement('dialog'); dialog.innerHTML=`<h2>QR claim · ${esc(sn)}</h2><img src="${image}" alt="QR claim ${esc(sn)}" style="width:280px;height:280px;display:block;margin:16px auto"><p>${esc(claim)}</p><button onclick="window.print()">Print</button> <button>Tutup</button>`; document.body.append(dialog); dialog.querySelectorAll('button')[1].onclick=()=>dialog.remove(); dialog.showModal(); }
function login() {
 app.innerHTML=`<section class="card login"><h1>RizIO<span style="color:#299d89">.</span></h1><p>Ruang kendali administrator</p><form id="login"><label>Alamat API<input name="base" value="${esc(base)}" required></label><label>Email<input name="email" type="email" autocomplete="username" required></label><label>Kata sandi<input name="password" type="password" autocomplete="current-password" required></label><button>Masuk</button></form><div id="notice" role="status"></div><p class="muted">Sesi bertahan saat halaman di-reload dan berakhir saat tab ditutup.</p></section>`;
 document.querySelector<HTMLFormElement>('form')!.onsubmit=async e=>{e.preventDefault();const f=e.currentTarget as HTMLFormElement;const d=data(f);base=String(d.base).replace(/\/$/,'');if(!base.startsWith('/')&&!base.startsWith('https://')&&!/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?\/v1$/.test(base)){notice('Gunakan URL HTTPS atau /v1.',true);return;}localStorage.setItem('rizio_api',base);const button=f.querySelector('button')!;button.disabled=true;try{const r=await api('/auth/login','POST',{email:d.email,password:d.password});if(r.user.role!=='admin')throw new Error('Akun administrator diperlukan.');access=r.access_token;refresh=r.refresh_token;await render();}catch(e){notice(String(e),true);button.disabled=false;}};
}
const pages=['Dashboard','Pengguna','Perangkat','Online','Offline','Firmware','OTA','Perintah','Log','Sistem'];
function rows(value:any):Row[]{return Array.isArray(value)?value:value?.items||value?.devices||value?.users||value?.firmwares||value?.commands||value?.logs||[];}
function table(items:Row[],columns:string[],action?:(r:Row)=>string):string{return items.length?`<div class="table"><table><thead><tr>${columns.map(c=>`<th>${esc(c.replaceAll('_',' '))}</th>`).join('')}${action?'<th>Tindakan</th>':''}</tr></thead><tbody>${items.map(r=>`<tr>${columns.map(c=>`<td>${esc(typeof r[c]==='object'?JSON.stringify(r[c]):r[c])}</td>`).join('')}${action?`<td>${action(r)}</td>`:''}</tr>`).join('')}</tbody></table></div>`:'<p>Belum ada data.</p>';}
async function render(){
 app.innerHTML=`<div class="shell"><aside><h2>RizIO.</h2><nav>${pages.map(p=>`<button data-page="${p}" class="${p===page?'active':''}">${p}</button>`).join('')}</nav></aside><main><header><div><div class="muted">ADMINISTRATOR / RIZIO CLOUD</div><h1>${page}</h1></div><div class="toolbar">${page==='Perangkat'?'<button id="add-device">+ Tambah perangkat</button>':''}<button id="reload" class="secondary">Perbarui</button><button id="logout" class="secondary">Keluar</button></div></header><div id="notice" role="status"></div><section id="content" aria-live="polite"><p>Memuat dataâ€¦</p></section></main></div>`;
 document.querySelectorAll<HTMLButtonElement>('[data-page]').forEach(b=>b.onclick=()=>{page=b.dataset.page!;void render();});
 document.querySelector<HTMLButtonElement>('#reload')!.onclick=()=>void render();
 document.querySelector<HTMLButtonElement>('#add-device')?.addEventListener('click',()=>{const form=document.querySelector('#device-form');form?.scrollIntoView({behavior:'smooth',block:'start'});(form?.querySelector('[name="sn"]') as HTMLInputElement|undefined)?.focus();});
 document.querySelector<HTMLButtonElement>('#logout')!.onclick=async()=>{try{await api('/auth/logout','POST',{refresh_token:refresh});}catch{}access='';refresh='';sessionStorage.removeItem('rizio_refresh');login();};
 const currentPage=page;const content=document.querySelector('#content')!;
 try {
  if(page==='Dashboard') {const s=await api('/admin/summary');content.innerHTML=`<div class="stats">${Object.entries(s).filter(([,v])=>typeof v!=='object').map(([k,v])=>`<div class="card stat"><span class="muted">${esc(k.replaceAll('_',' '))}</span><strong>${esc(v)}</strong></div>`).join('')}</div><div class="card"><h2>Distribusi firmware & koneksi</h2><pre>${esc(JSON.stringify(s,null,2))}</pre></div>`;}
  else if(page==='Pengguna') {const users=rows(await api('/admin/users'));content.innerHTML=`<div class="card"><h2>Tambah pengguna</h2><form id="user-form" class="grid"><label>Nama<input name="name" required></label><label>Email<input name="email" type="email" required></label><label>Password<input name="password" type="password" minlength="12" required></label><button>Tambah pengguna</button></form></div><div class="card">${table(users,['id','name','email','role','status','created_at'],r=>`<button data-user-status="${esc(r.id)}" data-value="${r.status!=='active'}" class="secondary">${r.status==='active'?'Nonaktifkan':'Aktifkan'}</button>`)}</div>`;document.querySelector<HTMLFormElement>('#user-form')!.onsubmit=e=>{e.preventDefault();const values=data(e.currentTarget as HTMLFormElement);void act(async()=>{await api('/admin/users','POST',{name:values.name,email:values.email,password:values.password});await render();});};document.querySelectorAll<HTMLButtonElement>('[data-user-status]').forEach(b=>b.onclick=()=>void act(async()=>{await api('/admin/users/'+encodeURIComponent(b.dataset.userStatus!),'PATCH',{status:b.dataset.value==='true'?'active':'disabled'});await render();}));}
  else if(['Perangkat','Online','Offline'].includes(page)) {let devices=rows(await api('/admin/devices'));if(page==='Online')devices=devices.filter(d=>d.online);if(page==='Offline')devices=devices.filter(d=>!d.online);content.innerHTML=`<div class="card">${table(devices,['sn','name','model','firmware_version','owner_user_id','online','disabled','last_seen'],r=>`<button data-qr="${esc(r.sn)}" class="secondary">View QR</button> <button data-info="${esc(r.sn)}" class="secondary">Telemetri</button> <button data-identity="${esc(r.sn)}" class="secondary">View identity.json</button> <button data-edit="${esc(r.sn)}" class="secondary">Edit</button> <button data-disable="${esc(r.sn)}" data-value="${!r.disabled}">${r.disabled?'Aktifkan':'Nonaktifkan'}</button>`)}</div>`;document.querySelectorAll<HTMLButtonElement>('[data-qr]').forEach(b=>b.onclick=()=>showClaimQr(b.dataset.qr!));document.querySelectorAll<HTMLButtonElement>('[data-identity]').forEach(b=>b.onclick=()=>{const identity=sessionIdentities.get(b.dataset.identity!);const dialog=document.createElement('dialog');dialog.innerHTML=identity?`<h2>identity.json · ${esc(b.dataset.identity)}</h2><pre>${esc(JSON.stringify(identity,null,2))}</pre><button id="download">Download</button> <button>Tutup</button>`:`<h2>identity.json tidak tersedia</h2><p>Device key hanya ditampilkan saat inventory dibuat dan tidak dapat diambil ulang dari backend.</p><button>Tutup</button>`;document.body.append(dialog);const buttons=dialog.querySelectorAll<HTMLButtonElement>('button');if(identity)buttons[0].onclick=()=>downloadFile('identity.json',JSON.stringify(identity,null,2)+'\n');buttons[buttons.length-1].onclick=()=>dialog.remove();dialog.showModal();});document.querySelectorAll<HTMLButtonElement>('[data-edit]').forEach(b=>b.onclick=()=>act(async()=>{const device=devices.find(d=>d.sn===b.dataset.edit);const name=prompt('Nama perangkat:',device?.name||'');if(name&&name.trim()&&name.trim()!==device?.name){await api('/admin/devices/'+encodeURIComponent(b.dataset.edit!),'PATCH',{name:name.trim()});await render();}}));document.querySelectorAll<HTMLButtonElement>('[data-disable]').forEach(b=>b.onclick=()=>act(async()=>{if(!confirm(`${b.textContent} ${b.dataset.disable}?`))return;await api('/admin/devices/'+encodeURIComponent(b.dataset.disable!),'PATCH',{disabled:b.dataset.value==='true'});await render();}));document.querySelectorAll<HTMLButtonElement>('[data-info]').forEach(b=>b.onclick=()=>{const device=devices.find(d=>d.sn===b.dataset.info);const dialog=document.createElement('dialog');dialog.innerHTML=`<h2>Telemetri ${esc(device?.sn)}</h2><pre>${esc(JSON.stringify(device,null,2))}</pre><button>Tutup</button>`;document.body.append(dialog);dialog.querySelector('button')!.onclick=()=>dialog.remove();dialog.showModal();});}
  else if(page==='Firmware') {content.innerHTML=`<div class="card"><h2>Daftarkan firmware</h2><form id="firmware"><div class="grid">${['model','hardware_version','version','url','checksum','file_size'].map(n=>`<label>${n}<input name="${n}" required ${n==='file_size'?'type="number" min="1"':n==='url'?'type="url"':''}></label>`).join('')}</div><label>Catatan rilis<textarea name="release_notes"></textarea></label><button>Daftarkan</button></form><p class="muted">Unggah binary ke hosting HTTPS Anda, lalu masukkan URL dan SHA256. Pilih file untuk menghitung checksum dan ukuran.</p><input id="binary" type="file" accept=".bin"><button id="upload">Unggah binary ke server</button></div><div class="card">${table(rows(await api('/admin/firmwares')),['id','model','hardware_version','version','file_size','is_active'])}</div>`;document.querySelector<HTMLInputElement>('#binary')!.onchange=async e=>{const file=(e.target as HTMLInputElement).files?.[0];if(!file)return;const hash=await crypto.subtle.digest('SHA-256',await file.arrayBuffer());(document.querySelector('[name="checksum"]') as HTMLInputElement).value=Array.from(new Uint8Array(hash)).map(b=>b.toString(16).padStart(2,'0')).join('');(document.querySelector('[name="file_size"]') as HTMLInputElement).value=String(file.size);};document.querySelector<HTMLButtonElement>('#upload')!.onclick=()=>act(async()=>{const f=document.querySelector<HTMLFormElement>('#firmware')!;const binary=document.querySelector<HTMLInputElement>('#binary')!.files?.[0];if(!binary)throw new Error('Pilih file binary terlebih dahulu.');const body=new FormData();body.set('file',binary);for(const key of ['model','hardware_version','version','release_notes'])body.set(key,String(data(f)[key]||''));const r=await fetch(base+'/admin/firmwares/upload',{method:'POST',headers:{Authorization:'Bearer '+access},body});const result=await r.json();if(!r.ok)throw new Error(result.message||'Upload gagal');await render();notice('Binary firmware tersimpan.');});document.querySelector<HTMLFormElement>('#firmware')!.onsubmit=e=>{e.preventDefault();const d=data(e.currentTarget as HTMLFormElement);act(async()=>{await api('/admin/firmwares','POST',{...d,file_size:Number(d.file_size)});await render();notice('Metadata firmware disimpan.');});};}
  else if(page==='OTA') {const [ds,fs]=await Promise.all([api('/admin/devices'),api('/admin/firmwares')]);content.innerHTML=`<div class="card"><h2>Deployment firmware</h2><form id="ota"><label>Perangkat<select name="sn">${rows(ds).map(d=>`<option value="${esc(d.sn)}">${esc(d.name||d.sn)} Â· ${esc(d.model)} / ${esc(d.hardware_version)}</option>`).join('')}</select></label><label>Firmware<select name="firmware_id">${rows(fs).map(f=>`<option value="${esc(f.id)}">${esc(f.model)} / ${esc(f.hardware_version)} Â· ${esc(f.version)}</option>`).join('')}</select></label><button>Kirim OTA</button></form><p class="muted">Pantau ACK pada menu Perintah dan versi perangkat sesudah restart.</p></div>`;document.querySelector<HTMLFormElement>('#ota')!.onsubmit=e=>{e.preventDefault();const d=data(e.currentTarget as HTMLFormElement);act(async()=>{if(!confirm('Kirim pembaruan firmware ke perangkat ini?'))return;const r=await api('/admin/devices/'+encodeURIComponent(d.sn)+'/ota','POST',{firmware_id:d.firmware_id});notice(`OTA diantrikan. ID: ${r.request_id}. Menunggu konfirmasi perangkat.`);});};}
  else if(page==='Perintah')content.innerHTML=`<div class="card">${table(rows(await api('/admin/commands')),['request_id','sn','command','command_status','created_at','ack_at'])}</div>`;
  else if(page==='Log')content.innerHTML=`<div class="card">${table(rows(await api('/admin/logs')),['sn','event_type','payload','created_at'])}</div>`;
  else {const r=await fetch(base.replace(/\/v1$/,'')+'/health');content.innerHTML=`<div class="card"><h2>Kesehatan layanan</h2><pre>${esc(JSON.stringify(await r.json(),null,2))}</pre></div>`;}
 }catch(e){if(currentPage===page) {content.innerHTML='<div class="card"><p>Data tidak dapat dimuat. Gunakan Perbarui untuk mencoba kembali.</p></div>';notice(String(e),true);}}
}
async function act(work:()=>Promise<void>){if(busy)return;busy=true;document.querySelectorAll<HTMLButtonElement>('main button').forEach(b=>b.disabled=true);try{await work();}catch(e){notice(String(e),true);}finally{busy=false;document.querySelectorAll<HTMLButtonElement>('main button').forEach(b=>b.disabled=false);}}
void restoreSession();

function installDeviceInventoryForm() {
  const content = document.querySelector('#content');
  const title = document.querySelector('header h1')?.textContent;
  if (!content || title !== 'Perangkat' || content.querySelector('#device-inventory')) return;
  const card = document.createElement('section');
  card.className = 'card';
  card.id = 'device-inventory';
  card.innerHTML = `<h2>Tambah perangkat produksi</h2><p class="muted">Buat inventory sebelum firmware di-flash. Credential produksi hanya ditampilkan sekali.</p><form id="device-form"><div class="grid"><label>SN / Device ID<input name="sn" placeholder="ESP-A7F9C231" pattern="[A-Z0-9-]{3,64}" required></label><label>Nama perangkat<input name="name" placeholder="Living Room Light" required></label><label>Model<input name="model" value="ESP-RELAY-2CH" required></label><label>Hardware version<input name="hardware_version" value="1.0" required></label><label>Firmware version<input name="firmware_version" value="1.0.0" required></label></div><label>Channels JSON<textarea name="channels" rows="5" required>[{"id":1,"pin":4,"name":"Relay 1","type":"switch","active_low":true}]</textarea></label><button type="submit">Buat inventory</button></form>`;
  content.prepend(card);
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
        hardware_version: values.hardware_version,
        firmware_version: values.firmware_version,
        capabilities: { switch: Array.isArray(channels) ? channels.length : 0 },
        channels,
      });
      const credentials = result.production_credentials;
      const qr = `ESPCTRL://claim?sn=${encodeURIComponent(credentials.sn)}&code=${encodeURIComponent(credentials.claim_code)}`;
      const identity = {
        sn: credentials.sn,
        device_key: credentials.device_key,
        setup_code: credentials.setup_code,
        claim_code: credentials.claim_code,
        model: values.model,
        hardware_version: values.hardware_version,
        mqtt_host: 'mqtt.rizbill.my.id',
        mqtt_port: 8883,
        reset_pin: 0,
        channels,
      };
      sessionIdentities.set(String(credentials.sn), identity);
      const dialog = document.createElement('dialog');
      dialog.innerHTML = `<h2>Credential produksi</h2><p>Simpan data ini sekarang. Backend tidak menyediakan endpoint untuk mengambil ulang credential ini.</p><label>SN<input readonly value="${esc(credentials.sn)}"></label><label>Device key<input readonly value="${esc(credentials.device_key)}"></label><label>Setup code<input readonly value="${esc(credentials.setup_code)}"></label><label>Isi QR claim<textarea readonly rows="3">${esc(qr)}</textarea></label><div class="dialog-actions"><button id="download-identity">Download identity.json</button><button id="download-qr" class="secondary">Download claim-qr.txt</button><button id="download-label" class="secondary">Download setup-label.txt</button></div><button id="close-dialog" class="secondary">Tutup</button>`;
      document.body.append(dialog);
      dialog.querySelector<HTMLButtonElement>('#download-identity')!.onclick = () => downloadFile('identity.json', JSON.stringify(identity, null, 2) + '\n');
      dialog.querySelector<HTMLButtonElement>('#download-qr')!.onclick = () => downloadFile('claim-qr.txt', qr + '\n');
      dialog.querySelector<HTMLButtonElement>('#download-label')!.onclick = () => downloadFile('setup-label.txt', `SN: ${credentials.sn}\nSSID: RIZIO-${String(credentials.sn).slice(-8)}\nSetup/AP password: ${credentials.setup_code}\n`);
      dialog.querySelector<HTMLButtonElement>('#close-dialog')!.onclick = () => dialog.remove();
      dialog.showModal();
      await render();
    });
  };
}

const inventoryObserver = new MutationObserver(() => installDeviceInventoryForm());
inventoryObserver.observe(app, { childList: true, subtree: true });


