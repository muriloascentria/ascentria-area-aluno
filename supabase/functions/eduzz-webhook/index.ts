// Eduzz como gateway de pagamento do Essência Plat.
//  - myeduzz.invoice_paid: cria a conta (convite por e-mail para a pessoa definir a senha) e libera o acesso
//    do produto comprado (Método Essência = Método / curso gravado).
//  - reembolso / chargeback: bloqueia o login da conta que foi criada por aquela compra.
//  - ping: só responde 200 (ativação da URL na Eduzz).
// Segurança: header x-signature = HMAC-SHA256(segredo, corpo bruto). Segredo no secret EDUZZ_WEBHOOK_SECRET.
import { createClient } from 'npm:@supabase/supabase-js@2'

const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { 'Content-Type': 'application/json' } })
const BLOQUEIA = ['myeduzz.invoice_refunded', 'myeduzz.invoice_chargeback']

async function hmac(secret: string, body: string) {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(body)))
  const hex = Array.from(sig).map((b) => b.toString(16).padStart(2, '0')).join('')
  const b64 = btoa(String.fromCharCode(...sig))
  return { hex, b64 }
}
function igual(a: string, b: string) {
  if (a.length !== b.length) return false
  let r = 0
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return r === 0
}
const semAcento = (s: string) => (s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
/* Sem produto cadastrado em eduzz_produtos, o nome decide: "Método" libera o Método (curso gravado). */
function acessoPorNome(nome: string): string | null {
  const n = semAcento(nome)
  if (/pos[- ]?gradua/.test(n)) return null // ainda não liberado pela Eduzz
  if (/metodo/.test(n)) return 'curso'
  return null
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ ok: true })
  const raw = await req.text()
  let ev: any = {}
  try { ev = JSON.parse(raw) } catch { return json({ error: 'json inválido' }, 400) }
  if (ev?.event === 'ping') return json({ ok: true })

  const secret = Deno.env.get('EDUZZ_WEBHOOK_SECRET') ?? ''
  const assinatura = (req.headers.get('x-signature') ?? '').trim()
  if (!secret) return json({ error: 'segredo não configurado' }, 401)
  const { hex, b64 } = await hmac(secret, raw)
  if (!assinatura || !(igual(assinatura.toLowerCase(), hex) || igual(assinatura, b64))) return json({ error: 'assinatura inválida' }, 401)

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
  const d = ev.data ?? {}
  const pessoa = d.student?.email ? d.student : (d.buyer ?? {})
  const email = String(pessoa.email ?? '').trim().toLowerCase()
  const nome = String(pessoa.name ?? '').trim()
  const fatura = String(d.id ?? '')
  const evId = String(ev.id ?? `${ev.event}:${fatura}`)

  // Evento repetido (a Eduzz reenvia em caso de falha): não processa duas vezes.
  const { data: ja } = await admin.from('eduzz_eventos').select('id, resultado').eq('id', evId).maybeSingle()
  if (ja?.resultado && !ja.resultado.startsWith('erro')) return json({ ok: true, repetido: true })
  await admin.from('eduzz_eventos').upsert({ id: evId, evento: ev.event, fatura_id: fatura, email, payload: ev })
  const fim = async (resultado: string, extra: Record<string, unknown> = {}) => {
    await admin.from('eduzz_eventos').update({ resultado }).eq('id', evId)
    return json({ ok: true, resultado, ...extra })
  }

  try {
    if (ev.event === 'myeduzz.invoice_paid') {
      // Qual acesso a compra libera (o primeiro item que libera alguma coisa).
      let acesso: string | null = null
      for (const it of (d.items ?? [])) {
        const pid = String(it.productId ?? '')
        const { data: p } = await admin.from('eduzz_produtos').select('acesso').eq('product_id', pid).maybeSingle()
        if (!p) await admin.from('eduzz_produtos').insert({ product_id: pid, nome: it.name ?? null, acesso: acessoPorNome(it.name ?? '') })
        const a = p ? p.acesso : acessoPorNome(it.name ?? '')
        if (a) { acesso = a; break }
      }
      if (!acesso) return await fim('ignorado: produto não libera acesso no ePLAT')
      if (!email) return await fim('erro: compra sem e-mail')

      let alunoId: string | null = (await admin.rpc('eduzz_usuario_por_email', { p_email: email })).data ?? null
      let criada = false
      if (!alunoId) {
        const partes = nome.split(/\s+/).filter(Boolean)
        const iniciais = (partes.slice(0, 2).map((x) => x[0]).join('') || email.slice(0, 2)).toUpperCase()
        const { data: conv, error } = await admin.auth.admin.inviteUserByEmail(email, { data: { name: nome || email.split('@')[0], initials: iniciais, origem: 'eduzz' } })
        if (error) throw error
        alunoId = conv.user?.id ?? null
        criada = true
      } else {
        // Conta já existia (comprou de novo, ou foi bloqueada num reembolso): libera o login.
        await admin.auth.admin.updateUserById(alunoId, { ban_duration: 'none' })
      }
      if (!alunoId) throw new Error('conta não criada')

      const { data: prof } = await admin.from('profiles').select('tier, role').eq('id', alunoId).maybeSingle()
      // Nunca rebaixa: quem já é mentorado (ou equipe) continua como está.
      if (prof && prof.role === 'aluno' && (criada || prof.tier === 'curso')) {
        await admin.from('profiles').update({ tier: 'curso', bonus: acesso === 'curso_bonus', pos: acesso === 'curso_pos' }).eq('id', alunoId)
      }
      if (criada) {
        const fone = String(pessoa.cellphone || pessoa.phone || '')
        await admin.from('student_cadastro').update({ nome_completo: nome || null, telefone: fone || null, cpf: pessoa.document || null, data_matricula: new Date().toISOString().slice(0, 10) }).eq('student_id', alunoId)
      }
      await admin.from('eduzz_acessos').upsert({ fatura_id: fatura, aluno_id: alunoId, email, acesso, conta_criada: criada, status: 'liberado', atualizado_em: new Date().toISOString() })
      return await fim(criada ? `conta criada e convite enviado (${acesso})` : `acesso liberado na conta existente (${acesso})`, { aluno: alunoId })
    }

    if (BLOQUEIA.includes(ev.event)) {
      const { data: ac } = await admin.from('eduzz_acessos').select('*').eq('fatura_id', fatura).maybeSingle()
      if (!ac?.aluno_id) return await fim('ignorado: fatura sem acesso liberado')
      if (!ac.conta_criada) {
        await admin.from('eduzz_acessos').update({ status: 'bloqueado', atualizado_em: new Date().toISOString() }).eq('fatura_id', fatura)
        return await fim('conta já existia antes da compra: não bloqueada, avisar a equipe')
      }
      await admin.auth.admin.updateUserById(ac.aluno_id, { ban_duration: '876000h' })
      await admin.from('eduzz_acessos').update({ status: 'bloqueado', atualizado_em: new Date().toISOString() }).eq('fatura_id', fatura)
      return await fim('acesso bloqueado (' + ev.event + ')')
    }

    return await fim('ignorado: evento sem ação')
  } catch (e) {
    console.error('eduzz-webhook', evId, (e as Error).message)
    await admin.from('eduzz_eventos').update({ resultado: 'erro: ' + (e as Error).message }).eq('id', evId)
    return json({ ok: false, error: (e as Error).message }, 500)
  }
})
