// Convida uma pessoa da equipe de um mentor para o Mentores Essência dele (só a equipe interna chama).
// Cria a conta por convite (e-mail "Convite · Mentores Essência", ramo tipo=me_convidado do template de
// convite), troca o papel para me_convidado e registra o vínculo em me_convidados.
import { createClient } from 'npm:@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } })

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'método não permitido' }, 405)
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })

  const jwt = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '')
  const { data: u } = await admin.auth.getUser(jwt)
  if (!u?.user) return json({ error: 'não autenticado' }, 401)
  const { data: quem } = await admin.from('profiles').select('role, name').eq('id', u.user.id).maybeSingle()
  if (!quem || quem.role !== 'staff') return json({ error: 'Só a equipe interna pode convidar.' }, 403)

  let body: any = {}
  try { body = await req.json() } catch { return json({ error: 'corpo inválido' }, 400) }
  const titularId = String(body.titular_id ?? '')
  const nome = String(body.nome ?? '').trim()
  const email = String(body.email ?? '').trim().toLowerCase()
  if (!titularId || !nome || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: 'Informe nome e e-mail válidos.' }, 400)

  const { data: t } = await admin.from('profiles').select('id, name, genero, profissao, mentor_essencia, role').eq('id', titularId).maybeSingle()
  if (!t || t.role !== 'aluno') return json({ error: 'Mentor não encontrado.' }, 404)
  if (!t.mentor_essencia) return json({ error: 'Este aluno não está com o Mentores Essência liberado.' }, 400)

  const { data: existe } = await admin.rpc('eduzz_usuario_por_email', { p_email: email })
  if (existe) return json({ error: 'Esse e-mail já tem uma conta no ePLAT. Use outro e-mail para o convidado.' }, 409)

  const titularNome = String(t.name ?? '').trim()
  const prof = t.profissao === 'terapia' ? (t.genero === 'M' ? 'do terapeuta' : 'da terapeuta') : (t.genero === 'M' ? 'do enfermeiro' : 'da enfermeira')
  const partes = nome.split(/\s+/).filter(Boolean)
  const iniciais = (partes.length > 1 ? partes[0][0] + partes[partes.length - 1][0] : nome.slice(0, 2)).toUpperCase()

  const { data: conv, error } = await admin.auth.admin.inviteUserByEmail(email, {
    data: { name: nome, initials: iniciais, tipo: 'me_convidado', titular_nome: titularNome.split(/\s+/)[0], titular_desc: `${prof} ${titularNome}` },
  })
  if (error || !conv?.user) return json({ error: 'Falha ao enviar o convite: ' + (error?.message ?? 'conta não criada') }, 500)
  const uid = conv.user.id

  const { error: e1 } = await admin.from('profiles').update({ role: 'me_convidado' }).eq('id', uid)
  if (e1) return json({ error: 'Convite enviado, mas falhou ao ajustar o perfil: ' + e1.message }, 500)
  const { error: e2 } = await admin.from('me_convidados').insert({ titular_id: titularId, user_id: uid, email, nome, criado_por: u.user.id })
  if (e2) return json({ error: 'Convite enviado, mas falhou ao registrar o vínculo: ' + e2.message }, 500)
  return json({ ok: true, user_id: uid })
})
