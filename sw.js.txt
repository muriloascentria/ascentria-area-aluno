/* Ascentria — Área do Aluno
   Este arquivo é o que transforma o site em app instalado no celular.

   Regra principal: a PÁGINA é sempre buscada na internet primeiro. Assim, toda vez que o
   Murilo sobe uma atualização, todo mundo abre já na versão nova — nada de app velho preso
   no celular do aluno. A cópia guardada só entra em cena quando o celular está sem internet,
   para o app abrir mesmo assim em vez de dar erro.

   Nada do Supabase (dados, mensagens, áudios, arquivos) passa por aqui: é outro endereço e
   vai direto para a rede, sempre ao vivo. */

const CACHE = 'ascentria-v2';
const ESSENCIAIS = ['./', './index.html', './manifest.webmanifest', './icon-192.png', './icon-512.png', './apple-touch-icon.png'];

self.addEventListener('install', (e)=>{
  e.waitUntil(caches.open(CACHE).then(c=>c.addAll(ESSENCIAIS)).catch(()=>{}));
});

self.addEventListener('activate', (e)=>{
  e.waitUntil((async ()=>{
    const nomes = await caches.keys();
    await Promise.all(nomes.filter(n=>n!==CACHE).map(n=>caches.delete(n)));
    await self.clients.claim();
  })());
});

/* A página avisa quando o usuário aceita atualizar. */
self.addEventListener('message', (e)=>{ if(e.data==='ATUALIZAR_AGORA') self.skipWaiting(); });

self.addEventListener('fetch', (e)=>{
  const req = e.request;
  if(req.method !== 'GET') return;
  let url;
  try{ url = new URL(req.url); }catch(err){ return; }
  if(url.origin !== self.location.origin) return; // Supabase e CDNs: direto para a rede

  const ehPagina = req.mode === 'navigate' || req.destination === 'document';
  if(ehPagina){
    e.respondWith((async ()=>{
      try{
        const resp = await fetch(req);
        if(resp && resp.ok){ const c = await caches.open(CACHE); c.put('./index.html', resp.clone()); }
        return resp;
      }catch(err){
        const c = await caches.open(CACHE);
        return (await c.match('./index.html')) || (await c.match('./')) || Response.error();
      }
    })());
    return;
  }

  /* Ícones e afins: mostra a cópia guardada na hora e atualiza por baixo. */
  e.respondWith((async ()=>{
    const c = await caches.open(CACHE);
    const guardado = await c.match(req);
    if(guardado){
      fetch(req).then(r=>{ if(r && r.ok) c.put(req, r); }).catch(()=>{});
      return guardado;
    }
    try{
      const r = await fetch(req);
      if(r && r.ok) c.put(req, r.clone());
      return r;
    }catch(err){ return Response.error(); }
  })());
});

/* ---- Notificações (push) ----
   O aviso chega do servidor mesmo com o app fechado. Aqui a gente só desenha a notificação e,
   quando a pessoa toca nela, leva para o lugar certo dentro do app. */
self.addEventListener('push', (e)=>{
  let d = {};
  try{ d = e.data ? e.data.json() : {}; }
  catch(err){ d = { titulo: 'Essência', corpo: e.data ? e.data.text() : '' }; }
  const titulo = d.titulo || 'Essência';
  e.waitUntil(self.registration.showNotification(titulo, {
    body: d.corpo || '',
    icon: './icon-192.png',
    badge: './icon-192.png',
    tag: d.tag || 'ascentria',
    renotify: true,
    data: { url: d.url || './' },
  }));
});

self.addEventListener('notificationclick', (e)=>{
  e.notification.close();
  const destino = (e.notification.data && e.notification.data.url) || './';
  e.waitUntil((async ()=>{
    const abas = await self.clients.matchAll({ type:'window', includeUncontrolled:true });
    for(const aba of abas){
      if(aba.url.startsWith(self.location.origin)){
        aba.postMessage({ tipo:'abrir', url: destino });
        if('focus' in aba) return aba.focus();
      }
    }
    return self.clients.openWindow(destino);
  })());
});
