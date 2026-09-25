/* Ascentria — Área do Aluno
   Este arquivo é o que transforma o site em app instalado no celular.

   Regra principal: a PÁGINA é sempre buscada na internet primeiro. Assim, toda vez que o
   Murilo sobe uma atualização, todo mundo abre já na versão nova — nada de app velho preso
   no celular do aluno. A cópia guardada só entra em cena quando o celular está sem internet,
   para o app abrir mesmo assim em vez de dar erro.

   Nada do Supabase (dados, mensagens, áudios, arquivos) passa por aqui: é outro endereço e
   vai direto para a rede, sempre ao vivo. */

const CACHE = 'ascentria-v1';
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
